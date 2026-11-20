// <mctrot-pair>: a DoubleTake pair on /live (website/src/Live.elm renders it).
//
// DoubleTake films with the back camera (A) and the front camera (B) at
// once. The recorder makes two cuts of each pair, AB and BA, which switch
// cameras halfway through, and the pair's order (set on the upload page)
// picks one.
//
// - On a narrow screen (a phone), or when the browser says to save data
//   (Data Saver: navigator.connection.saveData): that one cut, with the
//   browser's own video controls.
// - On a wide screen: both clips side by side, first camera on the left,
//   playing in sync with one set of controls. Browsers have no built-in
//   way to group two videos under one set of controls (HTML once had
//   `mediagroup` and MediaController, removed for lack of support), so
//   the controls are made here. They cover what the HTML standard says
//   media controls should: play and pause, seeking, volume, and
//   fullscreen. These clips have no captions or alternative audio tracks.
//
// Attributes: cut, cut-poster, first, first-poster, second, second-poster.
// The first clip is the leader: its sound plays and the other follows it.

const WIDE = "(min-width: 48rem)";
// Two videos download twice as much: not for someone saving data.
const savingData = () => Boolean(navigator.connection && navigator.connection.saveData);
const DRIFT_S = 0.12; // resync the follower when it drifts more than this

const css = `
  :host { display: block; }
  video { display: block; width: 100%; height: auto; max-height: 70vh; object-fit: contain; background: #000; }
  .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; }
  .pair video { height: 100%; }
  .wrap:fullscreen { background: #000; display: flex; flex-direction: column; justify-content: center; }
  .wrap:fullscreen video { max-height: calc(100vh - 3rem); }
  .controls { display: flex; align-items: center; gap: 8px; padding: 6px 8px; background: #111; color: #fff;
    font: 0.85rem/1 -apple-system, Helvetica, Arial, sans-serif; }
  button { font: inherit; color: inherit; background: none; border: 0; padding: 4px 6px; cursor: pointer; min-width: 2rem; }
  button:focus-visible, input:focus-visible { outline: 2px solid #FFD100; outline-offset: 2px; }
  .seek { flex: 1; accent-color: #FFD100; min-width: 4rem; }
  .volume { width: 5rem; accent-color: #FFD100; }
  .time { font-variant-numeric: tabular-nums; white-space: nowrap; }
`;

const clock = (s) => {
  if (!Number.isFinite(s)) return "0:00";
  const m = Math.floor(s / 60);
  return `${m}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
};

class McTrotPair extends HTMLElement {
  static observedAttributes = ["cut", "cut-poster", "first", "first-poster", "second", "second-poster"];

  constructor() {
    super();
    this.attachShadow({ mode: "open" });
    this.wide = window.matchMedia(WIDE);
    this.onWidth = () => this.render();
  }

  connectedCallback() {
    this.wide.addEventListener("change", this.onWidth);
    this.render();
  }

  disconnectedCallback() {
    this.wide.removeEventListener("change", this.onWidth);
    this.stop?.();
  }

  attributeChangedCallback(_name, old, value) {
    if (old !== value && this.isConnected) this.render();
  }

  // Elm sets attributes one by one: render once they've all landed.
  render() {
    if (this.pending) return;
    this.pending = true;
    queueMicrotask(() => {
      this.pending = false;
      this.stop?.();
      this.stop = null;
      if (this.wide.matches && !savingData()) this.renderPair();
      else this.renderCut();
    });
  }

  video(src, poster) {
    const v = document.createElement("video");
    v.src = src ?? "";
    if (poster) v.poster = poster;
    v.preload = "metadata";
    v.playsInline = true;
    return v;
  }

  renderCut() {
    const style = document.createElement("style");
    style.textContent = css;
    const v = this.video(this.getAttribute("cut"), this.getAttribute("cut-poster"));
    v.controls = true;
    v.setAttribute("aria-label", "DoubleTake video: back and front cameras");
    this.shadowRoot.replaceChildren(style, v);
  }

  renderPair() {
    const style = document.createElement("style");
    style.textContent = css;
    const lead = this.video(this.getAttribute("first"), this.getAttribute("first-poster"));
    const follow = this.video(this.getAttribute("second"), this.getAttribute("second-poster"));
    follow.muted = true;
    lead.setAttribute("aria-label", "First camera");
    follow.setAttribute("aria-label", "Second camera");

    const wrap = document.createElement("div");
    wrap.className = "wrap";
    wrap.setAttribute("role", "group");
    wrap.setAttribute("aria-label", "DoubleTake video: both cameras side by side");
    const pair = document.createElement("div");
    pair.className = "pair";
    pair.append(lead, follow);

    const button = (label, text) => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("aria-label", label);
      b.textContent = text;
      return b;
    };
    const play = button("Play", "▶");
    const time = document.createElement("span");
    time.className = "time";
    const seek = document.createElement("input");
    Object.assign(seek, { type: "range", min: 0, max: 1000, value: 0, className: "seek" });
    seek.setAttribute("aria-label", "Seek");
    const mute = button("Mute", "🔊");
    const volume = document.createElement("input");
    Object.assign(volume, { type: "range", min: 0, max: 1, step: 0.05, value: 1, className: "volume" });
    volume.setAttribute("aria-label", "Volume");
    const full = button("Full screen", "⛶");
    const controls = document.createElement("div");
    controls.className = "controls";
    controls.append(play, time, seek, mute, volume, full);
    wrap.append(pair, controls);
    this.shadowRoot.replaceChildren(style, wrap);

    // --- Keeping the two in step: the follower does what the leader does.
    let wantPlaying = false;
    const sync = () => {
      if (Math.abs(follow.currentTime - lead.currentTime) > DRIFT_S) follow.currentTime = lead.currentTime;
    };
    const show = () => {
      const d = lead.duration;
      time.textContent = `${clock(lead.currentTime)} / ${clock(d)}`;
      if (!seeking && Number.isFinite(d) && d > 0) seek.value = String(Math.round((lead.currentTime / d) * 1000));
      const paused = lead.paused || lead.ended;
      play.textContent = paused ? "▶" : "⏸";
      play.setAttribute("aria-label", paused ? "Play" : "Pause");
      const silent = lead.muted || lead.volume === 0;
      mute.textContent = silent ? "🔇" : "🔊";
      mute.setAttribute("aria-label", silent ? "Unmute" : "Mute");
    };
    const start = () => {
      wantPlaying = true;
      if (lead.ended) lead.currentTime = 0;
      sync();
      Promise.all([lead.play(), follow.play()]).catch(() => {
        wantPlaying = false;
        lead.pause();
        follow.pause();
      });
    };
    const pause = () => {
      wantPlaying = false;
      lead.pause();
      follow.pause();
    };
    let seeking = false;

    const on = (el, type, fn) => el.addEventListener(type, fn);
    on(play, "click", () => (lead.paused || lead.ended ? start() : pause()));
    on(pair, "click", () => (lead.paused || lead.ended ? start() : pause()));
    on(seek, "input", () => {
      seeking = true;
      if (Number.isFinite(lead.duration)) lead.currentTime = (Number(seek.value) / 1000) * lead.duration;
    });
    on(seek, "change", () => {
      seeking = false;
    });
    on(mute, "click", () => {
      lead.muted = !lead.muted;
      if (!lead.muted && lead.volume === 0) lead.volume = volume.value = 0.5;
    });
    on(volume, "input", () => {
      lead.volume = Number(volume.value);
      lead.muted = lead.volume === 0;
    });
    on(full, "click", () => {
      if (document.fullscreenElement) document.exitFullscreen();
      else wrap.requestFullscreen?.().catch(() => {});
    });
    // Space or K plays and pauses, arrows step 5 s, as most players do.
    on(wrap, "keydown", (e) => {
      if (e.target instanceof HTMLInputElement) return;
      if (e.key === " " || e.key === "k") {
        e.preventDefault();
        lead.paused ? start() : pause();
      } else if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault();
        lead.currentTime = Math.max(0, lead.currentTime + (e.key === "ArrowLeft" ? -5 : 5));
      }
    });
    wrap.tabIndex = 0;

    on(lead, "seeked", sync);
    on(lead, "timeupdate", () => {
      if (wantPlaying && !lead.paused) sync();
      show();
    });
    on(lead, "volumechange", show);
    on(lead, "loadedmetadata", show);
    on(lead, "play", show);
    on(lead, "pause", show);
    on(lead, "ended", () => {
      wantPlaying = false;
      follow.pause();
      show();
    });
    // If either one stalls to load, hold the other until both can play.
    on(lead, "waiting", () => follow.pause());
    on(follow, "waiting", () => lead.pause());
    for (const v of [lead, follow]) {
      on(v, "canplay", () => {
        if (wantPlaying && (lead.paused || follow.paused)) start();
      });
    }
    show();
    this.stop = () => pause();
  }
}

customElements.define("mctrot-pair", McTrotPair);
