// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/framer_web"
import topbar from "../vendor/topbar"
import {LbsPreview, TimelineScrub, EditorKeys} from "./lbs_preview"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, LbsPreview, TimelineScrub, EditorKeys},
})

// Show the progress bar for live navigation and for pushes that opt in with
// page_loading: true; the matching stop event hides it.
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", (e) => {
  topbar.show()
  if (e.detail?.kind === "initial") {
    const clientLoader = document.getElementById("client-blocking-loader")
    if (clientLoader) clientLoader.remove()
  }
})
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  const clientLoader = document.getElementById("client-blocking-loader")
  if (clientLoader) clientLoader.remove()
})

// Immediate blocking overlay for actions that wait on a server operation. The
// control pushes with page_loading: true, so the matching phx:page-loading-stop
// above removes this overlay when the reply lands - it can never outlive the op.
window.addEventListener("click", (event) => {
  const trigger = event.target.closest("[data-wait-title], [data-wait-message]")
  if (!trigger) return

  const waitTitle = trigger.dataset.waitTitle
  const waitMessage = trigger.dataset.waitMessage
  if (!document.getElementById("blocking-loader") && !document.getElementById("client-blocking-loader")) {
    const overlay = document.createElement("div")
    overlay.id = "client-blocking-loader"
    overlay.role = "dialog"
    overlay.setAttribute("aria-modal", "true")
    overlay.className = "fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-xs select-none"
    overlay.innerHTML = `
      <div class="card w-96 max-w-[90vw] border border-base-300 bg-base-100 p-6 shadow-2xl flex flex-col items-center gap-3 text-center">
        <div class="flex items-center gap-2">
          <span class="loading loading-spinner loading-md text-primary"></span>
          <h3 class="text-sm font-semibold">${waitTitle || "Processing"}</h3>
        </div>
        <p class="text-xs opacity-75">${waitMessage || "Please wait..."}</p>
      </div>
    `
    document.body.appendChild(overlay)
  }
}, true)

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

