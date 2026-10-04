import Foundation

/// The research viewer reads only PNGs emitted by the same evaluation run. Its
/// images remain in native output geometry; measurement registration is never
/// applied to these visual comparisons. All files stay in the private output dir.
func viewerHTML(ids: [String]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ids)
    let pairIDs = String(data: data, encoding: .utf8)!
    return """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Camera RAW render comparison</title>
      <style>
        :root { color-scheme: light dark; font: 15px system-ui, sans-serif; }
        body { margin: 0; padding: 20px; background: Canvas; color: CanvasText; }
        main { max-width: 1180px; margin: auto; }
        h1 { font-size: 1.45rem; margin: 0 0 8px; }
        p { color: GrayText; line-height: 1.4; }
        .controls { display: flex; flex-wrap: wrap; gap: 12px 20px; align-items: end; margin: 18px 0; }
        label { display: grid; gap: 5px; font-weight: 600; }
        select, input { font: inherit; }
        select { min-width: 150px; padding: 5px; }
        .frame { width: min(100%, 1000px); aspect-ratio: 3 / 2; overflow: hidden;
                 position: relative; background: #252525; border: 1px solid GrayText; }
        .frame img { position: absolute; inset: 0; width: 100%; height: 100%;
                     object-fit: contain; transform-origin: var(--origin, 50% 50%);
                     transform: scale(var(--zoom, 1)); }
        #reference { clip-path: inset(0 calc(100% - var(--reveal, 50%)) 0 0); }
        .divider { position: absolute; top: 0; bottom: 0; left: var(--reveal, 50%);
                   border-left: 2px solid white; pointer-events: none; }
        .legend { display: flex; justify-content: space-between; width: min(100%, 1000px);
                  font-weight: 600; margin: 7px 0; }
        .note { max-width: 950px; }
        @media (prefers-reduced-motion: reduce) { *, *::before, *::after { transition: none !important; } }
      </style>
    </head>
    <body><main>
      <h1>Candidate compared with Camera</h1>
      <p class="note">A/B from this evaluation run. Full frames are 768-pixel previews;
        corner crops contain native-resolution pixels. Displayed images retain their
        own output geometry. Registration affects scores only.</p>
      <div class="controls">
        <label>Capture <select id="pair"></select></label>
        <label>Candidate <select id="candidate">
          <option value="fixed-model">Saved fixed model</option>
          <option value="apple">Apple default</option>
          <option value="neutral">Apple neutral</option>
        </select></label>
        <label>Area <select id="area">
          <option value="full">Full frame</option>
          <option value="tl">Native top left</option><option value="tr">Native top right</option>
          <option value="bl">Native bottom left</option><option value="br">Native bottom right</option>
        </select></label>
        <label>Zoom <input id="zoom" type="range" min="1" max="4" step="0.25" value="1"></label>
        <label>Camera reveal <input id="reveal" type="range" min="0" max="100" value="50"></label>
      </div>
      <div class="legend"><span id="candidateLabel">Saved fixed model</span><span>Camera camera render</span></div>
      <div class="frame" id="frame">
        <img id="render" alt="Selected RAW development">
        <img id="reference" alt="Camera camera render">
        <div class="divider"></div>
      </div>
      <p class="note">Tab through the controls to inspect without a mouse. A split at 0% shows
        the candidate; 100% shows Camera. The detail acceptance gate remains open.</p>
    </main>
    <script>
      const ids = \(pairIDs);
      const pair = document.querySelector('#pair');
      const candidate = document.querySelector('#candidate');
      const area = document.querySelector('#area');
      const zoom = document.querySelector('#zoom');
      const reveal = document.querySelector('#reveal');
      const frame = document.querySelector('#frame');
      for (const id of ids) pair.add(new Option(id, id));
      function update() {
        const id = pair.value;
        const prefix = area.value === 'full' ? id : `${id}/native-${area.value}`;
        document.querySelector('#render').src = `${prefix}/${candidate.value}.png`;
        document.querySelector('#reference').src = `${prefix}/camera.png`;
        document.querySelector('#candidateLabel').textContent = candidate.selectedOptions[0].textContent;
        frame.style.aspectRatio = area.value === 'full' ? '3 / 2' : '1 / 1';
        frame.style.setProperty('--origin', '50% 50%');
        frame.style.setProperty('--zoom', zoom.value);
        frame.style.setProperty('--reveal', `${reveal.value}%`);
      }
      area.addEventListener('change', () => { zoom.value = 1; update(); });
      for (const control of [pair, candidate, zoom, reveal]) control.addEventListener('input', update);
      update();
    </script>
    </body></html>
    """
}
