// Runs in WebKit's isolated client world. Page text is untrusted output.
(() => {
    if (globalThis.handshakeBrowser) return;
    const documentID = Math.random().toString(36).slice(2);
    const refs = new Map(), nodes = new WeakMap();
    let next = 0;
    const stale = () => { throw Error('Stale element reference. Take a new snapshot.'); };
    const currentDocument = doc => {
        let depth = 0;
        while (doc !== document) {
            if (++depth > 16) return false;
            const frame = doc.defaultView?.frameElement;
            if (!frame?.isConnected || frame.contentDocument !== doc) return false;
            doc = frame.ownerDocument;
        }
        return true;
    };
    const ref = node => {
        if (!nodes.has(node) || !refs.has(nodes.get(node)) || refs.get(nodes.get(node)).document !== node.ownerDocument) {
            if (refs.size >= 1000) refs.delete(refs.keys().next().value);
            nodes.set(node, documentID + ':' + (++next));
        }
        const id = nodes.get(node);
        refs.delete(id);
        refs.set(id, {node, document:node.ownerDocument});
        return id;
    };
    const visible = node => {
        const r = node.getBoundingClientRect();
        const style = node.ownerDocument.defaultView.getComputedStyle(node);
        if (!r.width || !r.height || style.visibility === 'hidden' || style.display === 'none') return false;
        const frame = node.ownerDocument.defaultView.frameElement;
        return !frame || visible(frame);
    };
    const element = id => {
        const entry = refs.get(id);
        if (!entry || !entry.node.isConnected || entry.node.ownerDocument !== entry.document || !currentDocument(entry.document)) stale();
        return entry.node;
    };
    const disabled = node => {
        if (node.matches(':disabled')) return true;
        for (let ancestor = node; ancestor; ancestor = ancestor.parentElement || ancestor.getRootNode().host || ancestor.ownerDocument.defaultView?.frameElement) {
            if (ancestor.hasAttribute('inert')) return true;
        }
        return false;
    };
    const focused = node => {
        for (let active = node; active;) {
            const root = active.getRootNode();
            if (root.activeElement !== active) return false;
            if (root === document) return true;
            active = root.host || root.defaultView?.frameElement;
        }
        return false;
    };
    const focusTarget = (node, id) => {
        node.focus({preventScroll:true});
        if (element(id) !== node || !focused(node)) throw Error('The page redirected focus.');
        available(node);
    };
    const available = node => {
        if (!visible(node) || disabled(node)) throw Error('Element is hidden or disabled.');
    };
    const contexts = () => {
        const roots = [], frames = [], pending = [document];
        let scanned = 0, truncated = false;
        while (pending.length && roots.length < 64) {
            const root = pending.pop();
            roots.push(root);
            const walker = root.ownerDocument?.createTreeWalker(root, NodeFilter.SHOW_ELEMENT) || root.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
            let node;
            while ((node = walker.nextNode())) {
                if (++scanned > 10000) { truncated = true; break; }
                if (node.shadowRoot) pending.push(node.shadowRoot);
                if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') {
                    const child = node.contentDocument;
                    const accessible = !!child && currentDocument(child);
                    frames.push({ref:ref(node),url:node.src || '',accessible});
                    if (accessible && visible(node)) pending.push(child);
                }
            }
            if (truncated) break;
        }
        return {roots,frames,truncated:truncated || pending.length > 0};
    };
    const text = roots => roots.map(root => root.nodeType === Node.DOCUMENT_NODE
        ? root.body?.innerText || '' : [...root.children].map(node => node.innerText || '').join('\n')).join('\n').slice(0,16000);
    const deepHit = (root, x, y) => {
        let hit = root.elementFromPoint(x,y), count = 0;
        while (hit?.shadowRoot && count++ < 32) {
            const inner = hit.shadowRoot.elementFromPoint(x,y);
            if (!inner || inner === hit) break;
            hit = inner;
        }
        return hit;
    };
    const contains = (node, hit) => {
        while (hit) {
            if (node === hit) return true;
            hit = hit.parentElement || hit.getRootNode().host;
        }
        return false;
    };
    const point = node => {
        node.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
        const box = node.getBoundingClientRect();
        let x = box.x + box.width / 2, y = box.y + box.height / 2, doc = node.ownerDocument, target = node;
        while (true) {
            if (!contains(target, deepHit(doc,x,y))) throw Error('Element is covered.');
            if (doc === document) return {x,y};
            const frame = doc.defaultView.frameElement;
            available(frame);
            // Rotated/skewed frame geometry cannot be reduced to viewport offsets safely.
            let ancestor = frame;
            while (ancestor) {
                const style = frame.ownerDocument.defaultView.getComputedStyle(ancestor);
                if (['transform','rotate','scale','translate','perspective'].some(key => style[key] && style[key] !== 'none')) throw Error('Transformed frames are not supported.');
                ancestor = ancestor.parentElement || ancestor.getRootNode().host;
            }
            const bounds = frame.getBoundingClientRect();
            const sx = bounds.width / frame.offsetWidth, sy = bounds.height / frame.offsetHeight;
            const style = frame.ownerDocument.defaultView.getComputedStyle(frame);
            x = bounds.x + (x + frame.clientLeft + parseFloat(style.paddingLeft)) * sx;
            y = bounds.y + (y + frame.clientTop + parseFloat(style.paddingTop)) * sy;
            target = frame; doc = frame.ownerDocument;
        }
    };
    globalThis.handshakeBrowser = {
        snapshot() {
            for (const [id, entry] of refs) if (!entry.node.isConnected || !currentDocument(entry.document)) refs.delete(id);
            const {roots,frames,truncated} = contexts(), elements = [];
            let more = truncated;
            for (const root of roots) {
                for (const node of root.querySelectorAll('a,button,input,textarea,select,[role],[contenteditable="true"]')) {
                    if (!visible(node)) continue;
                    if (elements.length === 150) { more = true; break; }
                    const name = node.getAttribute('aria-label') || node.labels?.[0]?.innerText || node.innerText || node.placeholder || '';
                    const item = {ref:ref(node),role:node.getAttribute('role') || node.tagName.toLowerCase(),name:name.slice(0,200),disabled:disabled(node),value:node.type === 'password' ? '[password]' : String(node.value || '').slice(0,200)};
                    if (node.tagName === 'SELECT') item.options = [...node.options].slice(0,100).map(option => ({value:option.value,label:option.label,disabled:option.disabled || option.parentElement?.disabled === true}));
                    elements.push(item);
                }
            }
            return {url:location.href,title:document.title,text:text(roots),elements,truncated:more,frames:frames.length,frameDetails:frames};
        },
        prepareKey({key}) {
            let node = document.activeElement;
            for (let depth = 0; node && depth < 32; depth++) {
                const child = node.shadowRoot?.activeElement || node.contentDocument?.activeElement;
                if (!child) break;
                node = child;
            }
            if (node?.tagName === 'SELECT' && !node.multiple && node.size <= 1 &&
                ['ArrowUp','ArrowDown','Space','Enter'].includes(key.split('+').pop()))
                throw Error('Use select or choose this native dropdown manually.');
            return true;
        },
        target({id, fill, focus = true, click = false}) {
            const node = element(id); available(node);
            const control = node.closest('select') || node.closest('label')?.control;
            if (click && control?.tagName === 'SELECT' && !control.multiple && control.size <= 1)
                throw Error('Use select or choose this native dropdown manually.');
            if (fill && !['INPUT','TEXTAREA'].includes(node.tagName)) throw Error('Fill supports text inputs and textareas.');
            if (fill && (node.readOnly || (node.tagName === 'INPUT' && !['text','search','url','tel','email'].includes(node.type)))) throw Error('This field requires user input.');
            const position = point(node);
            if (focus) focusTarget(node, id);
            if (fill) node.select();
            return position;
        },
        selection({id,value}) {
            const node = element(id); available(node); point(node);
            if (node.tagName !== 'SELECT' || node.multiple || node.size > 1) throw Error('Select supports single dropdowns.');
            const options = [...node.options].filter(option => !option.disabled && !option.parentElement?.disabled);
            const matches = options.filter(option => option.value === value);
            if (matches.length !== 1) throw Error('Expected exactly one enabled option with this value.');
            if (node.value === value) return {key:'',unchanged:true};
            const initial = option => option.label.trimStart().charAt(0).toLowerCase();
            const key = initial(matches[0]);
            if (!/^[a-z]$/.test(key) || options.filter(option => initial(option) === key).length !== 1)
                throw Error('Native selection requires a unique initial letter; select this dropdown manually.');
            focusTarget(node, id);
            return {key,unchanged:false};
        },
        selected({id,value}) { return element(id).value === value; },
        state({id,state}) {
            const node = element(id);
            if (state === 'hidden') return !visible(node);
            if (state === 'enabled') return visible(node) && !disabled(node);
            return visible(node);
        },
        scroll({dy}) { window.scrollBy({top:dy,behavior:'instant'}); return {x:scrollX,y:scrollY}; },
        contains({text:needle}) { return text(contexts().roots).includes(needle); }
    };
})();
