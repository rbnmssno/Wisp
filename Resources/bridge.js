// Connects soundcloud.com to the Wisp app.
//
// What plays comes from the page itself: the Media Session it fills for browsers (title, artist,
// artwork), the <audio> element's own events (playing, paused, position, volume) and the player bar
// (like button, track link). Nothing is polled: a change schedules one short report to the app.
// Commands from the app press the page's own buttons, so the site's interface always agrees.
(() => {
  if (window.__wisp) return;
  const post = (m) => { try { window.webkit.messageHandlers.wisp.postMessage(m); } catch (e) {} };
  const q = (s) => document.querySelector(s);

  let meta = null;            // { title, artist, album, artwork }
  let sessionState = "none";  // what the page says: playing, paused, none
  const handlers = {};        // action handlers the page registered (nexttrack, previoustrack…)
  let audio = null;           // the element that plays now
  let wantedVolume = null;    // a volume set from the app, kept across tracks
  let lastVolume = 1;         // what the listener hears; a fresh element says 1 until the site sets it
  let durationKnown = false;  // false from a track change until the new audio reports its length

  // --- Media Session: listen to what the page tells the browser.
  const ms = navigator.mediaSession;
  if (ms) {
    const proto = Object.getPrototypeOf(ms);
    const md = Object.getOwnPropertyDescriptor(proto, "metadata");
    if (md && md.set) {
      Object.defineProperty(ms, "metadata", {
        configurable: true,
        get() { return md.get.call(ms); },
        set(v) {
          md.set.call(ms, v);
          const next = v ? { title: v.title || "", artist: v.artist || "", album: v.album || "", artwork: bestArtwork(v.artwork) } : null;
          if (!meta || !next || meta.title !== next.title || meta.artist !== next.artist) durationKnown = false;
          meta = next;
          schedule();
        },
      });
    }
    const ps = Object.getOwnPropertyDescriptor(proto, "playbackState");
    if (ps && ps.set) {
      Object.defineProperty(ms, "playbackState", {
        configurable: true,
        get() { return ps.get.call(ms); },
        set(v) { ps.set.call(ms, v); sessionState = v; schedule(); },
      });
    }
    const setHandler = ms.setActionHandler.bind(ms);
    ms.setActionHandler = (action, handler) => {
      handlers[action] = handler;
      try { setHandler(action, handler); } catch (e) {}
    };
    // The system's Now Playing (Control Center, media keys, AirPods) is WebKit's own, filled from this
    // Media Session. The site registers only next and previous; play, pause and seek are added here and
    // go through the site's own buttons, so the site always agrees with what the system shows.
    const own = {
      play: () => window.__wisp.command("play"),
      pause: () => window.__wisp.command("pause"),
      seekto: (details) => window.__wisp.command("seek", details.seekTime),
    };
    for (const [action, handler] of Object.entries(own)) {
      try { setHandler(action, handler); } catch (e) {}
    }
  }

  function bestArtwork(list) {
    if (!list || !list.length) return "";
    const size = (a) => parseInt(String(a.sizes || "").split("x")[0], 10) || 0;
    return [...list].sort((a, b) => size(b) - size(a))[0].src || "";
  }

  // --- The <audio> element: SoundCloud keeps it out of the page, so catch it when it starts.
  const events = ["play", "playing", "pause", "seeked", "durationchange", "volumechange", "ended", "emptied"];
  function onAudio(e) {
    if (e.target !== audio) return;
    if (e.type === "durationchange" || e.type === "playing") durationKnown = isFinite(audio.duration) && audio.duration > 0;
    if (e.type === "volumechange" || e.type === "playing") lastVolume = audio.volume;
    schedule();
  }
  function watch(el) {
    if (el === audio) return;
    if (audio) events.forEach((e) => audio.removeEventListener(e, onAudio));
    audio = el;
    events.forEach((e) => el.addEventListener(e, onAudio));
    if (wantedVolume !== null) el.volume = wantedVolume;
    watchBar();
    schedule();
  }
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (this instanceof HTMLAudioElement) watch(this);
    return play.apply(this, arguments);
  };

  // --- The player bar: the like button and the track link change without any audio event.
  let barObserver = null;
  function watchBar() {
    const badge = q(".playControls__soundBadge");
    if (!badge || badge.__wisp) return;
    badge.__wisp = true;
    if (barObserver) barObserver.disconnect();
    barObserver = new MutationObserver(schedule);
    barObserver.observe(badge, { subtree: true, childList: true, attributes: true, attributeFilter: ["class", "href"] });
  }

  function likeButton() { return q(".playbackSoundBadge__like"); }
  function isPlaying() { return audio ? !audio.paused && !audio.ended : sessionState === "playing"; }

  function snapshot() {
    const link = q(".playbackSoundBadge__titleLink");
    const like = likeButton();
    // Between tracks the old element still holds the old length; wait for the new one.
    const duration = durationKnown && audio && isFinite(audio.duration) ? audio.duration : 0;
    const title = (meta && meta.title) || (link && link.title) || "";
    return {
      type: "state",
      id: link ? link.getAttribute("href") || "" : title,
      url: link ? link.href : "",
      title,
      artist: (meta && meta.artist) || "",
      album: (meta && meta.album) || "",
      artwork: (meta && meta.artwork) || "",
      duration,
      position: audio ? audio.currentTime || 0 : 0,
      playing: isPlaying(),
      hasTrack: !!title,
      liked: like ? like.classList.contains("sc-button-selected") : false,
      likeable: !!like,
      volume: wantedVolume !== null ? wantedVolume : lastVolume,
    };
  }

  let timer = null;
  function schedule() {
    if (timer) return;
    timer = setTimeout(() => { timer = null; post(snapshot()); }, 120);
  }

  // A real click, the way a person's arrives: some of the site's buttons listen to mousedown.
  function press(el) {
    if (!el) return false;
    const r = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, view: window, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2 };
    ["pointerdown", "mousedown", "pointerup", "mouseup", "click"].forEach((t) => el.dispatchEvent(new MouseEvent(t, at)));
    return true;
  }

  window.__wisp = {
    command(name, value) {
      switch (name) {
        case "playpause": press(q(".playControls__play")); break;
        case "play": if (!isPlaying()) press(q(".playControls__play")); break;
        case "pause": if (isPlaying()) press(q(".playControls__play")); break;
        case "next":
          if (handlers.nexttrack) handlers.nexttrack({ action: "nexttrack" }); else press(q(".skipControl__next"));
          break;
        case "previous":
          if (handlers.previoustrack) handlers.previoustrack({ action: "previoustrack" }); else press(q(".skipControl__previous"));
          break;
        case "seek":
          if (audio && isFinite(value)) audio.currentTime = Math.max(0, Math.min(value, audio.duration || value));
          break;
        case "volume":
          wantedVolume = Math.max(0, Math.min(1, Number(value) || 0));
          if (audio) audio.volume = wantedVolume;
          lastVolume = wantedVolume;
          schedule();
          break;
        case "like": press(likeButton()); break;
        case "search": { const s = q(".headerSearch__input"); if (s) { s.focus(); s.select(); } break; }
        case "refresh": post(snapshot()); break;
      }
    },
  };
  document.addEventListener("DOMContentLoaded", () => { watchBar(); schedule(); });
})();
