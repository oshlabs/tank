// tank_web entry. Gooey ships the design system and hooks; heavy widget hooks
// (chart, terminal, data table) are opt-in imports so the bundle only carries
// what the screens use. Path dep → ../../../gooey; a hex consumer would import
// from deps/gooey instead.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tank"
import topbar from "../vendor/topbar"
import {Hooks as GooeyHooks} from "../../../gooey/assets/js/gooey"
import {GooeyChart} from "../../../gooey/assets/js/hooks/chart"
import {GooeyDataTable} from "../../../gooey/assets/js/hooks/data_table"
import {GooeyTerminal} from "../../../gooey/assets/js/hooks/terminal"
import {GooeyLogViewer} from "../../../gooey/assets/js/hooks/log_viewer"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// No longpoll fallback in dev: the code reloader blocks the websocket upgrade
// while it compiles, and one blocked upgrade > 2.5s makes Phoenix memorize
// "longpoll" in sessionStorage for the tab's lifetime — turning a 2 Hz stats
// stream into a GET /live/longpoll storm. (Same note as gooey/showcase.)
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: process.env.NODE_ENV === "development" ? undefined : 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...GooeyHooks,
    GooeyChart,
    GooeyDataTable,
    GooeyTerminal,
    GooeyLogViewer,
    ...colocatedHooks,
  },
})

// Progress bar on live navigation and form submits.
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

// Theme ambient effects (the tank aquarium) stay off: the WebGL water and
// 30fps plant canvas cost real CPU behind the mostly-opaque screens. To bring
// the fish back, import initGooeyFx from gooey.js and call it here.

// Expose for web console debug: liveSocket.enableDebug(), etc.
window.liveSocket = liveSocket
