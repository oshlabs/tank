defmodule Tank.Image.UserTest do
  use ExUnit.Case, async: true

  alias Tank.Image.User

  setup do
    rootfs = Path.join(System.tmp_dir!(), "tank-user-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(rootfs, "etc"))

    File.write!(Path.join(rootfs, "etc/passwd"), """
    root:x:0:0:root:/root:/bin/sh
    nobody:x:65534:65534:nobody:/:/sbin/nologin
    app:x:1000:2000:app user:/home/app:/bin/sh
    """)

    File.write!(Path.join(rootfs, "etc/group"), """
    root:x:0:
    staff:x:50:
    app:x:2000:
    """)

    on_exit(fn -> File.rm_rf!(rootfs) end)
    {:ok, rootfs: rootfs}
  end

  test "an empty / nil / root spec is uid 0", %{rootfs: rootfs} do
    assert User.resolve(rootfs, nil) == {:ok, {0, 0}}
    assert User.resolve(rootfs, "") == {:ok, {0, 0}}
    assert User.resolve(rootfs, "root") == {:ok, {0, 0}}
  end

  test "a user name resolves to its passwd uid and primary gid", %{rootfs: rootfs} do
    assert User.resolve(rootfs, "app") == {:ok, {1000, 2000}}
    assert User.resolve(rootfs, "nobody") == {:ok, {65534, 65534}}
  end

  test "a numeric uid takes its passwd entry's gid", %{rootfs: rootfs} do
    assert User.resolve(rootfs, "1000") == {:ok, {1000, 2000}}
  end

  test "a numeric uid with no passwd entry takes gid 0", %{rootfs: rootfs} do
    assert User.resolve(rootfs, "4242") == {:ok, {4242, 0}}
  end

  test "user:group resolves each part, names or numbers", %{rootfs: rootfs} do
    assert User.resolve(rootfs, "app:staff") == {:ok, {1000, 50}}
    assert User.resolve(rootfs, "1000:50") == {:ok, {1000, 50}}
    assert User.resolve(rootfs, "app:777") == {:ok, {1000, 777}}
  end

  test "an unknown name is an error", %{rootfs: rootfs} do
    assert User.resolve(rootfs, "ghost") == {:error, {:unknown_user, "ghost"}}
    assert User.resolve(rootfs, "app:ghosts") == {:error, {:unknown_group, "ghosts"}}
  end
end
