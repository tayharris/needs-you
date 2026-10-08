// The GitHub repo, in one place. While the repo is private these links 404 for
// visitors; they go live when it's public. Links carry data-repo="<path>" and a
// matching href for readers without JS; tests/test_site.py keeps the two in step.
var REPO_URL = "https://github.com/tayharris/needs-you";

(function () {
  document.querySelectorAll("a[data-repo]").forEach(function (a) {
    a.href = REPO_URL + a.getAttribute("data-repo");
  });
})();

// Copy buttons, only on code blocks marked data-copy: commands that run exactly as written.
// Examples with placeholders get none; the real commands come from the app's invite flow.
// Progressive enhancement: the page works without it.
(function () {
  if (!navigator.clipboard) return;
  document.querySelectorAll(".code[data-copy]").forEach(function (block) {
    var code = block.querySelector("code");
    if (!code) return;
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy";
    btn.textContent = "Copy";
    btn.setAttribute("aria-label", "Copy command to clipboard");
    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(code.textContent).then(function () {
        btn.textContent = "Copied";
        setTimeout(function () { btn.textContent = "Copy"; }, 1600);
      }, function () {
        btn.textContent = "Press ⌘C";
      });
    });
    block.classList.add("has-copy");
    block.appendChild(btn);
  });
})();

// The live demo on the landing page (#demo): the pill loops through example alerts. Each
// one springs out of the pill, a pointer clicks its link button, the card is marked done
// and the pill settles, then the next. It pauses while the tab is hidden, while it's
// scrolled out of view, and when the reader presses Pause. With reduced motion it never
// starts: the page shows the first alert, still (the HTML is that frame).
(function () {
  var demo = document.getElementById("demo");
  if (!demo || !window.requestAnimationFrame || !window.Promise) return;
  var motion = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  if (motion && motion.matches) return;

  // Example items only: placeholder hosts and names, in the app's layout.
  var EXAMPLES = [
    { prio: "urgent", title: "Claude needs permission: acme-api", meta: "devbox · claude-code",
      label: "VS Code", dest: "vscode",
      arrive: "Claude Code on devbox stops to ask before it runs a migration in acme-api.",
      after: "One click opens the session in VS Code on devbox. The card is done." },
    { prio: "normal", title: "Review requested: acme-web #412", meta: "devbox · github",
      label: "PR #412", dest: "github.com",
      arrive: "Someone asked for your review on GitHub.",
      after: "The pull request opens on github.com, and the card clears." },
    { prio: "urgent", title: "Approve the prod deploy of acme-api v2.14", meta: "build-box · deploy-bot",
      label: "Approve", dest: "ci.example.com",
      arrive: "A deploy is paused at its approval gate, waiting for a yes.",
      after: "The approval page on ci.example.com opens. The card is done." },
    { prio: "normal", title: "Nightly export failed: acme-api", meta: "build-box · cron:nightly-export",
      label: "Run log", dest: "ci.example.com",
      arrive: "A cron job failed overnight and said so, instead of failing quietly in a log.",
      after: "The run's log opens, and the card is done." }
  ];

  var screen = demo.querySelector(".demo-screen");
  var slot = demo.querySelector(".demo-slot");
  var pv = demo.querySelector(".pv");
  var body = demo.querySelector(".pv-body");
  var link = demo.querySelector(".pv-link");
  var cursor = demo.querySelector(".demo-cursor");
  var ripple = demo.querySelector(".demo-ripple");
  var toggle = demo.querySelector(".demo-toggle");
  var field = {};
  demo.querySelectorAll("[data-demo]").forEach(function (el) { field[el.getAttribute("data-demo")] = el; });
  var still = { cls: pv.className, caption: field.caption.textContent };

  // A clock that only runs while the demo is on screen, the tab is visible and it isn't paused.
  var userPaused = false, inView = true, waiting = null, raf = 0, last = 0, stopped = false;
  function running() { return !stopped && !userPaused && inView && !document.hidden; }
  function frame(t) {
    raf = 0;
    if (!waiting) return;
    if (last) waiting.left -= t - last;
    last = t;
    if (waiting.left <= 0) { var done = waiting.done; waiting = null; last = 0; done(); return; }
    if (running()) raf = requestAnimationFrame(frame); else last = 0;
  }
  function kick() { if (!raf && waiting && running()) raf = requestAnimationFrame(frame); }
  function wait(ms) { return new Promise(function (resolve) { waiting = { left: ms, done: resolve }; kick(); }); }
  function update() {
    if (running()) kick(); else if (raf) { cancelAnimationFrame(raf); raf = 0; last = 0; }
  }

  function measure() {
    demo.style.setProperty("--slot-w", slot.clientWidth + "px");
    demo.style.setProperty("--pv-h", body.offsetHeight + "px");
  }
  function fill(ex) {
    pv.className = "pv pv-" + ex.prio;
    field.title.textContent = ex.title;
    field.meta.textContent = ex.meta;
    field.label.textContent = ex.label;
    field.dest.textContent = ex.dest;
    measure();
  }
  function place(el, x, y) {
    el.style.setProperty(el === cursor ? "--cx" : "--rx", Math.round(x) + "px");
    el.style.setProperty(el === cursor ? "--cy" : "--ry", Math.round(y) + "px");
  }
  function restart(el, cls) { el.classList.remove(cls); el.getBoundingClientRect(); el.classList.add(cls); }

  function play() {
    var i = 0;
    function next() {
      var ex = EXAMPLES[i++ % EXAMPLES.length], t;
      pv.setAttribute("data-state", "idle");
      return wait(1100).then(function () {
        fill(ex);
        field.caption.textContent = ex.arrive;
        pv.setAttribute("data-state", "open");
        restart(pv, "is-arriving");
        return wait(1800);
      }).then(function () {
        // The pointer comes in from below and moves onto the link button's centre.
        var s = screen.getBoundingClientRect(), b = link.getBoundingClientRect();
        t = { x: b.left - s.left + b.width * 0.55, y: b.top - s.top + b.height * 0.55 };
        cursor.classList.add("no-move");
        place(cursor, s.width * 0.3, s.height + 6);
        cursor.getBoundingClientRect();
        cursor.classList.remove("no-move");
        cursor.classList.add("is-shown");
        place(cursor, t.x, t.y);
        return wait(950);
      }).then(function () {
        link.classList.add("is-hover");
        return wait(450);
      }).then(function () {
        cursor.classList.add("is-down");
        link.classList.add("is-pressed");
        place(ripple, t.x, t.y);
        restart(ripple, "is-on");
        return wait(170);
      }).then(function () {
        cursor.classList.remove("is-down");
        link.classList.remove("is-pressed", "is-hover");
        pv.setAttribute("data-state", "done");
        field.caption.textContent = ex.after;
        return wait(600);
      }).then(function () {
        cursor.classList.remove("is-shown");
        return wait(1900);
      }).then(next);
    }
    next();
  }

  demo.classList.add("is-live");
  measure();
  if (window.ResizeObserver) new ResizeObserver(measure).observe(slot);
  document.addEventListener("visibilitychange", update);
  if (window.IntersectionObserver) {
    new IntersectionObserver(function (entries) {
      inView = entries[entries.length - 1].isIntersecting;
      update();
    }).observe(demo);
  }
  // Reduced motion turned on mid-loop: stop, and go back to the still frame.
  if (motion && motion.addEventListener) {
    motion.addEventListener("change", function (e) {
      if (!e.matches) return;
      stopped = true;
      update();
      demo.classList.remove("is-live");
      pv.className = still.cls;
      pv.setAttribute("data-state", "open");
      field.caption.textContent = still.caption;
      fill(EXAMPLES[0]);
      pv.className = still.cls;
      toggle.hidden = true;
    });
  }
  toggle.hidden = false;
  toggle.addEventListener("click", function () {
    userPaused = !userPaused;
    toggle.textContent = userPaused ? "Play" : "Pause";
    update();
  });
  play();
})();
