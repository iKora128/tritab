// TriTab の紹介ページ: ダウンロードのリンク、コマンドのコピー、言語の記憶、ジェスチャーのデモ
(function () {
  "use strict";

  var ja = (document.documentElement.lang || "").indexOf("ja") === 0;
  var text = ja
    ? {
        version: "バージョン ",
        steps: {
          left: ["左へスワイプ", "次のタブ"],
          right: ["右へスワイプ", "前のタブ"],
          down: ["下へスワイプ", "タブを閉じる"],
          up: ["上へスワイプ", "閉じたタブを復元"],
          pinch: ["親指でつまむ", "再読み込み"],
          tap: ["タップ", "新しいタブ"]
        }
      }
    : {
        version: "Version ",
        steps: {
          left: ["Swipe left", "Next tab"],
          right: ["Swipe right", "Previous tab"],
          down: ["Swipe down", "Close tab"],
          up: ["Swipe up", "Reopen closed tab"],
          pinch: ["Pinch with your thumb", "Reload"],
          tap: ["Tap", "New tab"]
        }
      };

  function store(kind) {
    try { return window[kind]; } catch (e) { return null; }
  }

  // ---- 言語を選び直したら覚えておく（英語のページの自動切り替えを止めるため） ----
  document.querySelectorAll("[data-set-lang]").forEach(function (a) {
    a.addEventListener("click", function () {
      try { store("localStorage").setItem("tritab-lang", a.getAttribute("data-set-lang")); } catch (e) {}
    });
  });

  // ---- ダウンロードのボタンを、最新版の DMG への直接のリンクにする ----
  // 取得できなければ、リリースのページへのリンクのまま
  function applyRelease(info) {
    document.querySelectorAll("[data-download]").forEach(function (a) { a.href = info.url; });
    document.querySelectorAll("[data-version]").forEach(function (el) { el.textContent = text.version + info.version; });
  }
  var cached = null;
  try { cached = JSON.parse(store("sessionStorage").getItem("tritab-release") || "null"); } catch (e) {}
  if (cached && cached.url && cached.version) {
    applyRelease(cached);
  } else if (window.fetch) {
    fetch("https://api.github.com/repos/iKora128/tritab/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
      .then(function (release) {
        var dmg = (release.assets || []).filter(function (a) { return /\.dmg$/i.test(a.name); })[0];
        if (!dmg) return;
        var info = { url: dmg.browser_download_url, version: String(release.tag_name || "").replace(/^v/, "") };
        applyRelease(info);
        try { store("sessionStorage").setItem("tritab-release", JSON.stringify(info)); } catch (e) {}
      })
      .catch(function () {});
  }

  // ---- Homebrew のコマンドをコピー ----
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    var timer = null;
    button.addEventListener("click", function () {
      var value = button.getAttribute("data-copy");
      var done = function () {
        button.classList.add("copied");
        clearTimeout(timer);
        timer = setTimeout(function () { button.classList.remove("copied"); }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(done, function () { selectCode(button); });
      } else {
        selectCode(button);
      }
    });
  });
  function selectCode(button) {
    var code = button.querySelector("code");
    if (!code) return;
    var range = document.createRange();
    range.selectNodeContents(code);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  // ---- デモ: トラックパッドの指の動きに合わせて、ブラウザのタブが変わる ----
  var demo = document.getElementById("demo");
  if (!demo) return;
  var reduce = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  var pad = demo.querySelector(".pad.big");
  var win = demo.querySelector(".win");
  var tabsEl = demo.querySelector(".tabs");
  var page = demo.querySelector(".page");
  var caption = demo.querySelector(".caption");
  var capParts = caption.children;
  var hud = demo.querySelector(".hud");
  var hudKeys = hud.querySelector(".hud-keys");
  var hudWhat = hud.querySelector(".hud-what");
  // ジェスチャーの代わりに押すキー（Safari や Chrome の場合。TriTabCore の AppProfile.browser と同じ）
  var KEYS = {
    left: ["⌃", "Tab"], right: ["⌃", "⇧", "Tab"], down: ["⌘", "W"],
    up: ["⇧", "⌘", "T"], pinch: ["⌘", "R"], tap: ["⌘", "T"]
  };
  var initialTabs = tabsEl.innerHTML;
  var closed = [];
  var STEP = 2800;     // 1 つのジェスチャーにかける時間（CSS の --dur と同じ）
  var ACT_AT = 950;    // 指が動き出してから、タブが変わるまで

  function tabs() { return [].slice.call(tabsEl.querySelectorAll(".tab:not(.closing)")); }
  function activeIndex() { return tabs().findIndex(function (t) { return t.classList.contains("on"); }); }

  function activate(el, flash) {
    tabs().forEach(function (t) { t.classList.toggle("on", t === el); });
    win.style.setProperty("--c", el.style.getPropertyValue("--c"));
    page.setAttribute("data-layout", el.getAttribute("data-layout"));
    if (flash) {
      el.classList.remove("pop");
      void el.offsetWidth; // 続けて同じタブが選ばれても、光らせ直す
      el.classList.add("pop");
    }
  }
  function next() { var t = tabs(); activate(t[Math.min(activeIndex() + 1, t.length - 1)], true); }
  function prev() { var t = tabs(); activate(t[Math.max(activeIndex() - 1, 0)], true); }
  function close() {
    var t = tabs(), i = activeIndex();
    if (t.length < 2) return;
    var el = t[i];
    closed.push({ el: el, index: i });
    activate(t[i + 1] || t[i - 1], true);
    el.classList.add("closing");
    setTimeout(function () { if (el.classList.contains("closing")) el.remove(); }, 400);
  }
  function insertAt(el, index) {
    el.classList.remove("closing");
    el.classList.add("opening");
    tabsEl.insertBefore(el, tabs()[index] || null);
    void el.offsetWidth; // いったん幅 0 の状態を描かせてから広げる
    el.classList.remove("opening");
    activate(el, true);
  }
  function reopen() {
    var last = closed.pop();
    if (last) insertAt(last.el, last.index);
  }
  function newTab() {
    var el = document.createElement("div");
    el.className = "tab";
    el.style.setProperty("--c", "#A1A1AA");
    el.setAttribute("data-layout", "new");
    el.innerHTML = '<i class="fav"></i><span></span>';
    el.lastChild.textContent = tabsEl.getAttribute("data-new-title") || "New Tab";
    insertAt(el, tabs().length);
  }
  function reload() {
    page.classList.remove("reloading");
    void page.offsetWidth;
    page.classList.add("reloading");
  }
  function reset() {
    tabsEl.innerHTML = initialTabs;
    closed = [];
    page.classList.remove("reloading");
    activate(tabsEl.querySelector(".tab.on"));
  }

  var steps = [
    ["left", next], ["left", next], ["right", prev], ["down", close],
    ["up", reopen], ["pinch", reload], ["tap", newTab], ["down", close]
  ];

  function setGesture(g) {
    pad.setAttribute("data-g", "");
    void pad.offsetWidth; // 同じジェスチャーが続いても、動きを最初からやり直す
    pad.setAttribute("data-g", g);
  }
  function setCaption(g) {
    var words = text.steps[g];
    caption.classList.add("swap");
    setTimeout(function () {
      capParts[0].textContent = words[0];
      capParts[2].textContent = words[1];
      caption.classList.remove("swap");
    }, 180);
  }

  // 画面の下に出す、押したキーの表示
  function fillHud(g) {
    hudKeys.textContent = "";
    KEYS[g].forEach(function (k) {
      var kbd = document.createElement("kbd");
      kbd.textContent = k;
      hudKeys.appendChild(kbd);
    });
    hudWhat.textContent = text.steps[g][1];
  }
  function showHud(g) { fillHud(g); hud.classList.add("show"); }
  function hideHud() { hud.classList.remove("show", "press"); }
  // 動きを減らす設定のときは、最初のジェスチャーのキーを出したままにする
  function still() { fillHud("left"); hud.classList.add("show"); }

  var run = { i: 0, on: false, timers: [], pending: null };
  function later(ms, fn) { run.timers.push(setTimeout(fn, ms)); }

  function play() {
    if (!run.on) return;
    if (run.i >= steps.length) {
      // ひと回りしたら、ふわっと最初の状態に戻す
      run.i = 0;
      win.classList.add("fade");
      later(450, function () { reset(); win.classList.remove("fade"); });
      later(1100, play);
      return;
    }
    var g = steps[run.i][0];
    run.pending = steps[run.i++][1];
    setGesture(g);
    setCaption(g);
    // キーの表示が出て、押し込まれた瞬間にタブが変わる
    later(ACT_AT - 220, function () { showHud(g); });
    later(ACT_AT, function () {
      hud.classList.add("press");
      var act = run.pending; run.pending = null; if (act) act();
    });
    later(ACT_AT + 170, function () { hud.classList.remove("press"); });
    later(ACT_AT + 1350, hideHud);
    later(STEP, play);
  }
  function start() {
    if (run.on || reduce.matches) return;
    run.on = true;
    play();
  }
  function stop() {
    if (!run.on) return;
    run.on = false;
    run.timers.forEach(clearTimeout);
    run.timers = [];
    hideHud();
    // 途中で止めたときも、タブの状態がジェスチャーとずれないよう、残っている動きを済ませる
    var act = run.pending;
    run.pending = null;
    if (act) act();
  }

  var inView = false;
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      inView = entries[0].isIntersecting;
      if (inView && !document.hidden) start(); else stop();
    }, { threshold: 0.3 }).observe(demo);
  } else {
    inView = true;
    start();
  }
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) stop(); else if (inView) start();
  });
  if (reduce.matches) still();
  if (reduce.addEventListener) {
    reduce.addEventListener("change", function () {
      if (reduce.matches) { stop(); still(); } else { hideHud(); if (inView) start(); }
    });
  }
})();
