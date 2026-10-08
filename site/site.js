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
