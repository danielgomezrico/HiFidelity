// HiFidelity Remote — vanilla ES2020. Polls /state every 800 ms with
// ETag-driven If-None-Match short-circuit; POSTs commands to the API.
// No build tooling, no npm. Runs in any modern Safari (macOS/iOS) or
// Chromium-based browser.
(function () {
  "use strict";

  var POLL_MS = 800;
  var BACKOFF_MS = 3000;

  var els = {
    title: document.getElementById("title"),
    artist: document.getElementById("artist"),
    album: document.getElementById("album"),
    art: document.getElementById("artwork"),
    artFallback: document.getElementById("art-fallback"),
    seek: document.getElementById("seek"),
    timeCurrent: document.getElementById("time-current"),
    timeTotal: document.getElementById("time-total"),
    btnPrev: document.getElementById("btn-prev"),
    btnNext: document.getElementById("btn-next"),
    btnToggle: document.getElementById("btn-toggle"),
    btnShuffle: document.getElementById("btn-shuffle"),
    btnRepeat: document.getElementById("btn-repeat"),
    btnFav: document.getElementById("btn-fav"),
    btnMute: document.getElementById("btn-mute"),
    playGlyph: document.getElementById("play-glyph"),
    muteGlyph: document.getElementById("mute-glyph"),
    vol: document.getElementById("vol"),
    conn: document.getElementById("conn-status"),
  };

  var state = null;
  var lastEtag = null;
  var seekDragging = false;
  var volDragging = false;
  var currentArtworkId = null;
  var pollTimer = null;

  function fmtTime(secs) {
    if (!isFinite(secs) || secs < 0) secs = 0;
    var s = Math.floor(secs);
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var sec = s % 60;
    if (h > 0) return h + ":" + String(m).padStart(2, "0") + ":" + String(sec).padStart(2, "0");
    return m + ":" + String(sec).padStart(2, "0");
  }

  function setConn(status, label) {
    els.conn.dataset.state = status;
    els.conn.textContent = label;
  }

  function render(s) {
    state = s;
    var t = s.currentTrack;
    if (t) {
      els.title.textContent = t.title || "—";
      els.artist.textContent = t.artist || "—";
      els.album.textContent = t.album || "";
      var artId = t.trackId;
      if (artId !== currentArtworkId) {
        currentArtworkId = artId;
        els.art.src = "/artwork/" + artId;
        els.art.style.display = "";
        els.artFallback.hidden = true;
      }
    } else {
      els.title.textContent = "Nothing playing";
      els.artist.textContent = "";
      els.album.textContent = "";
      currentArtworkId = null;
      els.art.removeAttribute("src");
      els.art.style.display = "none";
      els.artFallback.hidden = false;
    }

    if (!seekDragging) {
      var dur = s.duration > 0 ? s.duration : 0;
      els.seek.max = dur || 1;
      els.seek.value = Math.min(s.currentTime || 0, dur || 0);
      els.timeCurrent.textContent = fmtTime(s.currentTime || 0);
      els.timeTotal.textContent = fmtTime(dur);
    }
    if (!volDragging) {
      els.vol.value = s.volume == null ? 0.7 : s.volume;
    }

    els.playGlyph.textContent = s.isPlaying ? "❚❚" : "▶";
    els.btnToggle.setAttribute("aria-label", s.isPlaying ? "Pause" : "Play");
    els.btnShuffle.setAttribute("aria-pressed", s.isShuffleEnabled ? "true" : "false");
    els.btnRepeat.setAttribute("aria-pressed", s.repeatMode && s.repeatMode !== "off" ? "true" : "false");
    els.btnRepeat.firstElementChild.textContent = s.repeatMode === "one" ? "1↻" : "↻";
    els.btnFav.setAttribute("aria-pressed", t && t.isFavorite ? "true" : "false");
    els.btnMute.setAttribute("aria-pressed", s.isMuted ? "true" : "false");
    els.muteGlyph.textContent = s.isMuted ? "🔇" : "🔊";
  }

  function schedulePoll(delay) {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(pollState, delay);
  }

  function pollState() {
    var headers = {};
    if (lastEtag) headers["If-None-Match"] = lastEtag;
    fetch("/state", { headers: headers, cache: "no-store" }).then(function (r) {
      if (r.status === 304) {
        setConn("ok", "Live");
        schedulePoll(POLL_MS);
        return null;
      }
      if (!r.ok) throw new Error("HTTP " + r.status);
      var et = r.headers.get("ETag");
      if (et) lastEtag = et;
      setConn("ok", "Live");
      return r.json();
    }).then(function (json) {
      if (json) render(json);
      schedulePoll(POLL_MS);
    }).catch(function (err) {
      setConn("error", "Offline");
      schedulePoll(BACKOFF_MS);
    });
  }

  function postCmd(path, body) {
    var opts = { method: "POST" };
    if (body) {
      opts.headers = { "Content-Type": "application/json" };
      opts.body = JSON.stringify(body);
    }
    return fetch(path, opts).then(function (r) {
      // Force an immediate refresh so UI doesn't lag the polling cadence.
      schedulePoll(0);
      return r;
    }).catch(function (err) {
      setConn("error", "Offline");
    });
  }

  // Wire up controls
  els.btnPrev.addEventListener("click", function () { postCmd("/previous"); });
  els.btnNext.addEventListener("click", function () { postCmd("/next"); });
  els.btnToggle.addEventListener("click", function () { postCmd("/toggle"); });
  els.btnShuffle.addEventListener("click", function () { postCmd("/shuffle"); });
  els.btnRepeat.addEventListener("click", function () { postCmd("/repeat"); });
  els.btnFav.addEventListener("click", function () { postCmd("/favorite"); });
  els.btnMute.addEventListener("click", function () { postCmd("/mute"); });

  els.seek.addEventListener("mousedown", function () { seekDragging = true; });
  els.seek.addEventListener("touchstart", function () { seekDragging = true; }, { passive: true });
  function commitSeek() {
    var seconds = parseFloat(els.seek.value);
    if (isFinite(seconds)) postCmd("/seek", { seconds: seconds });
    seekDragging = false;
  }
  els.seek.addEventListener("mouseup", commitSeek);
  els.seek.addEventListener("touchend", commitSeek);
  els.seek.addEventListener("change", commitSeek);

  els.vol.addEventListener("mousedown", function () { volDragging = true; });
  els.vol.addEventListener("touchstart", function () { volDragging = true; }, { passive: true });
  function commitVol() {
    var v = parseFloat(els.vol.value);
    if (isFinite(v)) postCmd("/volume", { volume: v });
    volDragging = false;
  }
  els.vol.addEventListener("mouseup", commitVol);
  els.vol.addEventListener("touchend", commitVol);
  els.vol.addEventListener("change", commitVol);

  // Tap-to-toggle on artwork, for Apple-style remote feel.
  document.querySelector(".art-wrap").addEventListener("click", function () {
    postCmd("/toggle");
  });

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") schedulePoll(0);
  });

  pollState();
})();
