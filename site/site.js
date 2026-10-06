// Copy buttons for code blocks. Progressive enhancement: the page works without it.
(function () {
  if (!navigator.clipboard) return;
  document.querySelectorAll(".code").forEach(function (block) {
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
