defmodule Tank.Image.Tar do
  @moduledoc """
  Extracts an OCI image layer -- a gzipped tar -- into a directory.

  Why not `:erl_tar`: it refuses absolute and `..`-escaping symlinks as an
  anti-symlink-attack measure, with no opt-out. A container root filesystem
  legitimately contains absolute symlinks (`/bin/sh -> /bin/busybox` and many
  more), so `:erl_tar.extract` cannot assemble OCI layers. This module reads
  the tar itself and creates every entry, symlinks included.

  It understands the ustar format plus the GNU long-name (`L`/`K`) and PAX
  extended-header (`x`/`g`) extensions. Character/block devices and FIFOs are
  skipped -- creating them needs privilege and images rarely ship them in
  layers.

  OCI whiteout markers are honoured so layers stack correctly: `.wh.<name>`
  deletes a lower-layer entry, and `.wh..wh..opq` empties a directory of its
  lower-layer contents. The markers themselves are never written.
  """

  require Logger

  @block 512
  @zero :binary.copy(<<0>>, @block)

  @doc """
  Extracts the gzipped-tar layer at `path` into `dest` (created if absent).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec extract(Path.t(), Path.t()) :: :ok | {:error, term}
  def extract(path, dest) do
    with {:ok, gz} <- File.read(path) do
      entries = gz |> :zlib.gunzip() |> parse(%{}, [])
      File.mkdir_p!(dest)

      # A layer's whiteouts delete from the lower layers already on disk, so
      # they are applied before this layer's own entries -- that way a layer
      # that deletes and re-adds the same path nets to the new file.
      {whiteouts, reals} = Enum.split_with(entries, &whiteout?/1)
      Enum.each(whiteouts, &apply_whiteout(&1, dest))
      Enum.each(reals, &write_entry(&1, dest))

      # Directory permissions are applied last: a layer may carry a read-only
      # directory, and setting that mode before its contents are written would
      # block the writes.
      for %{type: :directory, name: name, mode: mode} <- reals,
          do: chmod(safe_join(dest, name), mode)

      :ok
    end
  rescue
    e -> {:error, {:tar, Exception.message(e)}}
  end

  # --- whiteouts ------------------------------------------------------------

  # An OCI whiteout marker is any entry whose basename begins ".wh.".
  defp whiteout?(%{name: name}), do: String.starts_with?(Path.basename(name), ".wh.")

  # ".wh..wh..opq" empties a directory of its lower-layer contents; any other
  # ".wh.<name>" deletes the lower-layer entry <name> from the same directory.
  defp apply_whiteout(%{name: name}, dest) do
    dir = Path.dirname(name)

    case Path.basename(name) do
      ".wh..wh..opq" ->
        target = safe_join(dest, dir)

        if File.dir?(target) do
          for child <- File.ls!(target), do: File.rm_rf!(Path.join(target, child))
        end

      ".wh." <> removed ->
        File.rm_rf!(safe_join(dest, Path.join(dir, removed)))
    end
  end

  # --- tar parsing ----------------------------------------------------------

  # parse/3 walks the archive block by block. `pending` holds the name/link/
  # size overrides a GNU or PAX meta-entry sets for the *next* real entry.
  # Returns the entries in archive order.
  defp parse(<<block::binary-size(@block), rest::binary>>, pending, acc)
       when block != @zero do
    header = parse_header(block)

    # Meta-entries are sized by their own header; a real entry's content size
    # can be overridden by a preceding PAX `size` record.
    size =
      case header.type do
        type when type in [:longname, :longlink, :pax, :global_pax] -> header.size
        _ -> pending[:size] || header.size
      end

    payload_len = round_up(size)

    case rest do
      <<payload::binary-size(payload_len), tail::binary>> ->
        handle(header, size, payload, tail, pending, acc)

      _ ->
        Enum.reverse(acc)
    end
  end

  # A zero block (or a short trailing remnant) ends the archive.
  defp parse(_trailing, _pending, acc), do: Enum.reverse(acc)

  # GNU long name / long link name: the payload is the value for the next entry.
  defp handle(%{type: :longname}, _size, payload, tail, pending, acc),
    do: parse(tail, Map.put(pending, :name, trim_nul(payload)), acc)

  defp handle(%{type: :longlink}, _size, payload, tail, pending, acc),
    do: parse(tail, Map.put(pending, :linkname, trim_nul(payload)), acc)

  # PAX extended header: merge its records as overrides for the next entry.
  defp handle(%{type: :pax}, _size, payload, tail, pending, acc),
    do: parse(tail, Map.merge(pending, parse_pax(payload, %{})), acc)

  # Global PAX header: would apply to all following entries; layers don't rely
  # on it, so it is ignored.
  defp handle(%{type: :global_pax}, _size, _payload, tail, pending, acc),
    do: parse(tail, pending, acc)

  # A real entry: apply any pending overrides and emit it; clear `pending`.
  defp handle(header, size, payload, tail, pending, acc) do
    entry = %{
      type: header.type,
      name: pending[:name] || header.name,
      linkname: pending[:linkname] || header.linkname,
      mode: header.mode,
      data: binary_part(payload, 0, size)
    }

    parse(tail, %{}, [entry | acc])
  end

  # Decode a 512-byte ustar header block.
  defp parse_header(block) do
    <<name::binary-size(100), mode::binary-size(8), _uid::binary-size(8), _gid::binary-size(8),
      size::binary-size(12), _mtime::binary-size(12), _chksum::binary-size(8),
      typeflag::binary-size(1), linkname::binary-size(100), magic::binary-size(6), _rest::binary>> =
      block

    name = trim_nul(name)
    prefix = block |> binary_part(345, 155) |> trim_nul()

    %{
      name: if(prefix != "" and ustar?(magic), do: prefix <> "/" <> name, else: name),
      mode: parse_octal(mode),
      size: parse_size(size),
      type: typeflag(typeflag),
      linkname: trim_nul(linkname)
    }
  end

  defp typeflag("0"), do: :regular
  defp typeflag(<<0>>), do: :regular
  defp typeflag("7"), do: :regular
  defp typeflag("1"), do: :hardlink
  defp typeflag("2"), do: :symlink
  defp typeflag("3"), do: :chardev
  defp typeflag("4"), do: :blockdev
  defp typeflag("5"), do: :directory
  defp typeflag("6"), do: :fifo
  defp typeflag("L"), do: :longname
  defp typeflag("K"), do: :longlink
  defp typeflag("x"), do: :pax
  defp typeflag("g"), do: :global_pax
  defp typeflag(_other), do: :unknown

  # Parse PAX records: a concatenation of "<len> <key>=<value>\n", where <len>
  # counts the whole record. We keep the keys that affect extraction.
  defp parse_pax(<<>>, acc), do: acc

  defp parse_pax(bin, acc) do
    case Integer.parse(bin) do
      {len, <<" ", _::binary>>} when len > 0 and byte_size(bin) >= len ->
        <<record::binary-size(len), rest::binary>> = bin

        acc =
          case record
               |> String.split(" ", parts: 2)
               |> List.last()
               |> String.trim_trailing("\n") do
            "path=" <> v -> Map.put(acc, :name, v)
            "linkpath=" <> v -> Map.put(acc, :linkname, v)
            "size=" <> v -> Map.put(acc, :size, String.to_integer(v))
            _ -> acc
          end

        parse_pax(rest, acc)

      _ ->
        acc
    end
  end

  # --- writing entries ------------------------------------------------------

  defp write_entry(%{type: :directory, name: name}, dest) do
    File.mkdir_p!(safe_join(dest, name))
  end

  defp write_entry(%{type: :regular, name: name, data: data, mode: mode}, dest) do
    path = safe_join(dest, name)
    File.mkdir_p!(Path.dirname(path))
    remove_existing(path)
    File.write!(path, data)
    chmod(path, mode)
  end

  defp write_entry(%{type: :symlink, name: name, linkname: target}, dest) do
    path = safe_join(dest, name)
    File.mkdir_p!(Path.dirname(path))
    remove_existing(path)
    File.ln_s!(target, path)
  end

  defp write_entry(%{type: :hardlink, name: name, linkname: target}, dest) do
    path = safe_join(dest, name)
    File.mkdir_p!(Path.dirname(path))
    remove_existing(path)
    File.ln!(safe_join(dest, target), path)
  end

  # Devices and FIFOs need privilege to create (mknod); skip them.
  defp write_entry(%{type: type, name: name}, _dest)
       when type in [:chardev, :blockdev, :fifo, :unknown] do
    Logger.debug("tank: skipping #{type} tar entry #{name}")
  end

  # --- helpers --------------------------------------------------------------

  # Join an archive entry name onto `dest`, dropping leading slashes and any
  # "." / ".." components so a layer can never write outside `dest`.
  defp safe_join(dest, name) do
    parts =
      name
      |> String.trim_leading("/")
      |> Path.split()
      |> Enum.reject(&(&1 in ["", ".", ".."]))

    case parts do
      [] -> dest
      parts -> Path.join([dest | parts])
    end
  end

  # A later layer overwrites an earlier entry; drop whatever is in the way
  # first (lstat, so a symlink itself is removed, not its target).
  defp remove_existing(path) do
    case File.lstat(path) do
      {:ok, _stat} -> File.rm_rf!(path)
      _missing -> :ok
    end
  end

  defp chmod(path, mode) when is_integer(mode) and mode > 0, do: File.chmod(path, mode)
  defp chmod(_path, _mode), do: :ok

  # Everything up to the first NUL -- ustar pads fixed-width fields with NULs.
  defp trim_nul(bin) do
    case :binary.split(bin, <<0>>) do
      [head | _] -> head
      [] -> bin
    end
  end

  defp ustar?(magic), do: String.starts_with?(magic, "ustar")

  defp parse_octal(bin) do
    case bin |> trim_nul() |> String.trim() do
      "" -> 0
      digits -> String.to_integer(digits, 8)
    end
  end

  # The size field is octal, except GNU's base-256 encoding for large files
  # (signalled by the high bit of the first byte).
  defp parse_size(<<first, rest::binary>> = bin) do
    if first >= 0x80,
      do: :binary.decode_unsigned(rest),
      else: parse_octal(bin)
  end

  defp round_up(0), do: 0
  defp round_up(n), do: div(n + @block - 1, @block) * @block
end
