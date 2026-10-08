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

// The live demo on the landing page (#demo): a working model of the pill.
// Visitors can press the link button (it says where it would go, and marks the card done),
// the card (opens the panel at it), the pill (opens the panel), Done in the panel, and
// "Send a test alert" (the next example arrives, with the command that would post it).
// Left alone, it plays itself: each example springs out of the pill, a pointer presses
// its link button, the card is marked done. Any interaction stops the pointer; it comes
// back after 10 s of quiet. The pointer pauses while the tab is hidden, while the demo is
// off screen, and when the reader presses Pause. With reduced motion there's no pointer and
// no springs, but it still works. Without JS the HTML is a still frame of EXAMPLES[0].
(function () {
  var demo = document.getElementById("demo");
  if (!demo || !window.requestAnimationFrame || !window.Promise) return;
  var motion = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  var calm = !!(motion && motion.matches);

  // Example items only: placeholder hosts and names, in the app's layout. `cmd` is what
  // would have posted it (shown, never copyable: the real commands come from an invite).
  var EXAMPLES = [
    { prio: "urgent", title: "Claude needs permission: acme-api", meta: "devbox · claude-code",
      label: "VS Code", dest: "vscode", opened: "VS Code",
      arrive: "Claude Code on devbox stops to ask before it runs a migration in acme-api.",
      after: "One click opens the session in VS Code on devbox. The card is done.",
      cmd: 'needs-you add --key "claude-code:devbox:acme-api" --priority urgent \\\n' +
           '  --agent claude-code --title "Claude needs permission: acme-api" \\\n' +
           '  --link "VS Code=vscode://vscode-remote/ssh-remote+devbox/home/dev/acme-api"' },
    { prio: "normal", title: "Review requested: acme-web #412", meta: "devbox · github",
      label: "PR #412", dest: "github.com", opened: "github.com",
      arrive: "Someone asked for your review on GitHub.",
      after: "The pull request opens on github.com, and the card clears.",
      cmd: 'needs-you add --key "github:acme-web#412:review" \\\n' +
           '  --agent github --title "Review requested: acme-web #412" \\\n' +
           '  --link "PR #412=https://github.com/acme/acme-web/pull/412"' },
    { prio: "urgent", title: "Approve the prod deploy of acme-api v2.14", meta: "build-box · deploy-bot",
      label: "Approve", dest: "ci.example.com", opened: "ci.example.com",
      arrive: "A deploy is paused at its approval gate, waiting for a yes.",
      after: "The approval page on ci.example.com opens. The card is done.",
      cmd: 'needs-you add --key "deploy:acme-api:v2.14" --priority urgent \\\n' +
           '  --agent deploy-bot --title "Approve the prod deploy of acme-api v2.14" \\\n' +
           '  --link "Approve=https://ci.example.com/deploys/acme-api/v2.14"' },
    { prio: "normal", title: "Nightly export failed: acme-api", meta: "build-box · cron:nightly-export",
      label: "Run log", dest: "ci.example.com", opened: "ci.example.com",
      arrive: "A cron job failed overnight and said so, instead of failing quietly in a log.",
      after: "The run's log opens, and the card is done.",
      cmd: 'needs-you add --key "cron:nightly-export" \\\n' +
           '  --agent cron:nightly-export --title "Nightly export failed: acme-api" \\\n' +
           '  --link "Run log=https://ci.example.com/runs/nightly-export/latest"' }
  ];
  var RANK = { urgent: 0, normal: 1, low: 2 };
  var QUIET_MS = 10000;

  function $(sel) { return demo.querySelector(sel); }
  var screen = $(".demo-screen"), slot = $(".demo-slot"), pv = $(".pv"), hit = $(".pv-hit");
  var body = $(".pv-body"), link = $(".pv-link"), panel = $(".pp"), closeBtn = $(".pp-close");
  var cursor = $(".demo-cursor"), ripple = $(".demo-ripple");
  var controls = $(".demo-controls"), send = $(".demo-send"), toggle = $(".demo-toggle");
  var cmdBox = $(".demo-cmd");
  var field = {};
  demo.querySelectorAll("[data-demo]").forEach(function (el) { field[el.getAttribute("data-demo")] = el; });

  // What's on screen. `items` are the waiting cards, oldest first; `preview` is the card
  // sprung out of the pill (`previewDone` once its link was pressed); `panelOpen` swaps the
  // pill for the panel. render() draws the pill from these.
  var items = [{ ex: EXAMPLES[0] }], preview = items[0], previewDone = false, panelOpen = false;
  var loopAt = 0, sendAt = 1, settleTimer = 0, quietTimer = 0, engaged = false;

  // ---- A clock that only runs while the demo is on screen, the tab is visible and the
  // reader hasn't paused it. Only the self-playing loop uses it.
  var userPaused = false, inView = true, waiting = null, raf = 0, last = 0, gen = 0;
  function running() { return !calm && !userPaused && inView && !document.hidden; }
  function frame(t) {
    raf = 0;
    if (!waiting) return;
    if (last) waiting.left -= t - last;
    last = t;
    if (waiting.left <= 0) { var done = waiting.done; waiting = null; last = 0; done(); return; }
    if (running()) raf = requestAnimationFrame(frame); else last = 0;
  }
  function kick() { if (!raf && waiting && running()) raf = requestAnimationFrame(frame); }
  // Resolves after `ms` of running time, unless the loop was stopped (gen moved on) first.
  function wait(ms) {
    var mine = gen;
    return new Promise(function (resolve) {
      waiting = { left: ms, done: function () { if (mine === gen) resolve(); } };
      kick();
    });
  }
  function update() {
    if (running()) kick(); else if (raf) { cancelAnimationFrame(raf); raf = 0; last = 0; }
  }

  // ---- Drawing.
  function measure() {
    demo.style.setProperty("--slot-w", slot.clientWidth + "px");
    demo.style.setProperty("--pv-h", body.offsetHeight + "px");
  }
  function topPrio() {
    return items.reduce(function (p, it) { return RANK[it.ex.prio] < RANK[p] ? it.ex.prio : p; }, "low");
  }
  function render() {
    var state = preview ? (previewDone ? "done" : "open") : items.length ? "count" : "idle";
    var ex = preview && preview.ex;
    pv.hidden = panelOpen;
    panel.hidden = !panelOpen;
    screen.classList.toggle("has-panel", panelOpen);
    pv.className = "pv pv-" + (ex ? ex.prio : items.length ? topPrio() : "normal");
    pv.setAttribute("data-state", state);
    field.count.textContent = items.length;
    if (ex) {
      field.title.textContent = ex.title;
      field.meta.textContent = ex.meta;
      field.label.textContent = ex.label;
      field.dest.textContent = ex.dest;
      field.done.textContent = "Opened " + ex.opened + " · marked done";
    }
    body.inert = !ex;
    link.disabled = state !== "open";
    hit.setAttribute("aria-label", state === "idle" ? "Nothing needs you. Open the panel"
      : state === "count" ? items.length + " waiting. Open the panel"
      : ex.title + ", needs you, " + ex.meta.replace(" · ", ", ") + ". Open the panel at this card");
    measure();
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }
  var CHECK = '<svg viewBox="0 0 10 10" focusable="false" aria-hidden="true"><path d="M1.5 5.5 4 8l4.5-6"/></svg>';
  var ARROW = '<svg class="pv-arrow" viewBox="0 0 8 8" focusable="false" aria-hidden="true"><path d="M1.5 6.5 6.5 1.5M2.5 1.5h4v4"/></svg>';

  // The panel: most urgent first, newest first within a priority, as in the app.
  // Returns the card for `target`, if it's there.
  function renderPanel(target) {
    var list = field.list, group = null, found = null;
    var sorted = items.slice().reverse().sort(function (a, b) { return RANK[a.ex.prio] - RANK[b.ex.prio]; });
    list.textContent = "";
    field.n.textContent = items.length;
    field.n.classList.toggle("is-zero", !items.length);
    if (!items.length) {
      var empty = el("p", "pp-empty");
      empty.innerHTML = CHECK;
      empty.appendChild(document.createTextNode("All clear in Work"));
      list.appendChild(empty);
    }
    sorted.forEach(function (it) {
      var ex = it.ex;
      if (ex.prio !== group) {
        group = ex.prio;
        list.appendChild(el("p", "pp-group pp-" + group, group.charAt(0).toUpperCase() + group.slice(1)));
      }
      var card = el("div", "pp-card pp-" + ex.prio);
      card.setAttribute("role", "group");
      card.setAttribute("aria-label", ex.title);
      card.tabIndex = -1;
      card.appendChild(el("p", "pp-title", ex.title));
      var meta = el("p", "pp-meta");
      meta.appendChild(el("span", "pp-kind", "needs you"));
      meta.appendChild(document.createTextNode(" · " + ex.meta));
      card.appendChild(meta);
      var chip = el("button", "pv-link pp-link");
      chip.type = "button";
      chip.appendChild(document.createTextNode(ex.label + " "));
      chip.appendChild(el("span", "pv-dest", ex.dest));
      chip.insertAdjacentHTML("beforeend", ARROW);
      chip.addEventListener("click", function () {
        say("Opened " + ex.opened + ". From the panel a link leaves the card open: press Done once it's handled.", true);
      });
      card.appendChild(chip);
      var done = el("button", "pp-done");
      done.type = "button";
      done.innerHTML = CHECK;
      done.appendChild(document.createTextNode("Done"));
      done.setAttribute("aria-label", "Done: " + ex.title);
      done.addEventListener("click", function () { markDone(it); });
      card.appendChild(done);
      if (it === target) found = card;
      list.appendChild(card);
    });
    return found;
  }

  function say(text, user) {
    // Only what the visitor caused is announced; the self-playing loop stays quiet.
    field.caption.setAttribute("aria-live", user ? "polite" : "off");
    field.caption.textContent = text;
  }
  function place(node, x, y) {
    node.style.setProperty(node === cursor ? "--cx" : "--rx", Math.round(x) + "px");
    node.style.setProperty(node === cursor ? "--cy" : "--ry", Math.round(y) + "px");
  }
  function restart(node, cls) { node.classList.remove(cls); node.getBoundingClientRect(); node.classList.add(cls); }
  // Bring a card into view in the panel's list and outline it briefly, as the app does.
  function flash(card) {
    if (!card) return;
    var list = field.list;
    list.scrollTop = card.offsetTop - (list.clientHeight - card.offsetHeight) / 2;
    restart(card, "is-target");
  }

  // ---- What happens. `user` is true when the visitor did it, false for the loop.
  function settleIn(ms) {
    clearTimeout(settleTimer);
    settleTimer = setTimeout(function () {
      if (!preview || panelOpen) return;
      var hadFocus = body.contains(document.activeElement);
      preview = null; previewDone = false;
      render();
      if (hadFocus) hit.focus();
    }, ms);
  }
  function arrive(ex, user) {
    clearTimeout(settleTimer);
    var it = items.filter(function (x) { return x.ex === ex; })[0];
    if (!it) { it = { ex: ex }; items.push(it); }   // the same key updates its card
    say(ex.arrive + (!user ? "" : panelOpen ? " It's in the panel." : " Press its button, or the card to open the panel."), user);
    if (panelOpen) { flash(renderPanel(it)); return; }
    preview = it; previewDone = false;
    render();
    restart(pv, "is-arriving");
    if (user) settleIn(9000);
  }
  function openLink(user) {
    var it = preview;
    if (!it || previewDone) return;
    items = items.filter(function (x) { return x !== it; });
    previewDone = true;
    if (user) hit.focus();   // the link button is about to go
    render();
    say(it.ex.after, user);
    if (user) settleIn(2600);
  }
  function openPanel(user) {
    clearTimeout(settleTimer);
    var target = preview && !previewDone ? preview : null;
    preview = null; previewDone = false; panelOpen = true;
    render();
    var card = renderPanel(target);
    flash(card);
    say(items.length ? "The panel: every card waiting, most urgent first. Done clears one." : "The panel, empty: nothing needs you.", user);
    if (user) (card || closeBtn).focus();
  }
  function closePanel(user) {
    panelOpen = false;
    render();
    if (user) {
      hit.focus();
      say(items.length ? "Back to the pill: " + items.length + " waiting." : "Back to the pill. Nothing needs you.", true);
    }
  }
  function markDone(it) {
    var i = items.slice().reverse().sort(function (a, b) { return RANK[a.ex.prio] - RANK[b.ex.prio]; }).indexOf(it);
    items = items.filter(function (x) { return x !== it; });
    say("Marked done: " + it.ex.title + ".", true);
    renderPanel(null);
    // Focus the card that took its place, else the one before, else Close.
    var dones = field.list.querySelectorAll(".pp-done");
    (dones[Math.min(i, dones.length - 1)] || closeBtn).focus();
  }

  // ---- The self-playing loop.
  function cycle(first) {
    var ex = EXAMPLES[loopAt++ % EXAMPLES.length], t;
    var ready = first ? wait(1800) : wait(300).then(function () {
      if (panelOpen) closePanel(false);
      if (preview) { preview = null; previewDone = false; render(); }
      return wait(1100);
    }).then(function () {
      arrive(ex, false);
      return wait(1800);
    });
    ready.then(function () {
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
      openLink(false);
      return wait(600);
    }).then(function () {
      cursor.classList.remove("is-shown");
      return wait(1900);
    }).then(function () { cycle(false); });
  }
  function stopLoop() {
    gen++;
    waiting = null;
    cursor.classList.remove("is-shown", "is-down");
    link.classList.remove("is-hover", "is-pressed");
  }
  function startLoop(first) {
    stopLoop();
    if (!calm) cycle(first);
  }

  // A press, key or focus in the demo hands it to the visitor and stops the pointer. It
  // comes back after QUIET_MS without one (moving the mouse over it counts), but not while
  // keyboard focus is inside the screen.
  function quietLater() {
    clearTimeout(quietTimer);
    quietTimer = setTimeout(function () {
      if (screen.contains(document.activeElement)) { quietLater(); return; }
      engaged = false;
      startLoop(false);
    }, QUIET_MS);
  }
  function interact(e) {
    if (e.target.closest && e.target.closest(".demo-toggle")) return;
    if (!engaged) { engaged = true; stopLoop(); }
    quietLater();
  }
  demo.addEventListener("pointerdown", interact);
  demo.addEventListener("keydown", interact);
  demo.addEventListener("focusin", interact);
  demo.addEventListener("pointermove", function () { if (engaged) quietLater(); });

  hit.addEventListener("click", function () { openPanel(true); });
  link.addEventListener("click", function () { openLink(true); });
  closeBtn.addEventListener("click", function () { closePanel(true); });
  panel.addEventListener("keydown", function (e) { if (e.key === "Escape") closePanel(true); });
  send.addEventListener("click", function () {
    var ex = EXAMPLES[sendAt++ % EXAMPLES.length];
    arrive(ex, true);
    field.cmd.textContent = ex.cmd;
    cmdBox.hidden = false;
  });
  toggle.addEventListener("click", function () {
    userPaused = !userPaused;
    toggle.textContent = userPaused ? "Play" : "Pause";
    if (!userPaused && engaged) { clearTimeout(quietTimer); engaged = false; startLoop(false); }
    update();
  });

  screen.inert = false;
  controls.hidden = false;
  toggle.hidden = calm;
  demo.classList.add("is-live");
  render();
  if (window.ResizeObserver) new ResizeObserver(measure).observe(slot);
  document.addEventListener("visibilitychange", update);
  if (window.IntersectionObserver) {
    new IntersectionObserver(function (entries) {
      inView = entries[entries.length - 1].isIntersecting;
      update();
    }).observe(demo);
  }
  // Reduced motion turned on or off while the page is open: the pointer stops or starts;
  // everything else keeps working.
  if (motion && motion.addEventListener) {
    motion.addEventListener("change", function (e) {
      calm = e.matches;
      toggle.hidden = calm;
      if (calm) stopLoop(); else if (!engaged) startLoop(false);
      update();
    });
  }
  startLoop(true);
})();
