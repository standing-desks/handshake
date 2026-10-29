enum BrowserInteractionFixture {
    static let html = #"""
        <title>Interactions</title>
        <style>body{padding:20px}input,button,select{margin:8px;padding:8px}
        iframe{width:600px;height:240px;border:7px solid;padding:11px 23px 19px 31px}</style>
        <select aria-label="Plan" id="plan"><option value="free">Free</option>
        <option disabled>Unavailable</option><option value="pro">Pro</option></select><p id="selected"></p>
        <button id="hover">Hover me</button><p id="hovered"></p>
        <div id="host"></div><p id="saved"></p><iframe id="outer"></iframe>
        <script>
        plan.addEventListener('change',e=>selected.textContent='plan:'+plan.value+':'+e.isTrusted);
        hover.addEventListener('mouseover',e=>hovered.textContent='hover:'+e.isTrusted);
        const root=host.attachShadow({mode:'open'});
        root.innerHTML='<input aria-label="Shadow note"><button>Save shadow</button>';
        root.querySelector('button').addEventListener('click',e=>{
            saved.textContent='shadow:'+root.querySelector('input').value+':'+e.isTrusted;
        });
        outer.srcdoc='<iframe style="width:500px;height:180px"></iframe>';
        outer.onload=()=>{
            const inner=outer.contentDocument.querySelector('iframe');
            if(inner)inner.srcdoc=`<p>Frame ready</p><input aria-label="Frame note" id="note">
                <button onclick="result.textContent='frame:'+note.value+':'+event.isTrusted">Save frame</button>
                <p id="result"></p>`;
        };
        </script>
        """#
}
