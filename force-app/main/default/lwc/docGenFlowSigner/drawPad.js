import { cropRect, fitAspect, fitWidth } from './signerCore';

/**
 * Free-hand signature pad. Same stroke as the signing page's DrawPad (2.5px, round caps,
 * #16324f), but pointer-events based and instance-scoped instead of reading global element ids.
 *
 * onChange() fires once per completed stroke and on clear, never per move event, so callers can
 * validate cheaply while the stroke itself stays immediate.
 *
 * toPng() exports a tight crop of the ink, not the whole pad: see cropRect in signerCore.js for why
 * (embedding the full pad took ~5 s per mark under Lightning Web Security). The ink's bounding box
 * is tracked as points arrive, which is O(1) per event, rather than by scanning pixels, which
 * would be slow for the same reason.
 */
const EXPORT_MAX_WIDTH = 480;

export function createDrawPad(canvas, onChange) {
    const ctx = canvas.getContext('2d');
    let drawing = false;
    let inked = false;
    let bounds = null;

    function configure(ratio) {
        const scale = ratio || 1;
        ctx.lineWidth = 2.5 * scale;
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        ctx.strokeStyle = '#16324f';
    }

    function track(p) {
        if (!bounds) {
            bounds = { minX: p.x, minY: p.y, maxX: p.x, maxY: p.y };
            return;
        }
        if (p.x < bounds.minX) bounds.minX = p.x;
        if (p.y < bounds.minY) bounds.minY = p.y;
        if (p.x > bounds.maxX) bounds.maxX = p.x;
        if (p.y > bounds.maxY) bounds.maxY = p.y;
    }

    function pos(e) {
        const r = canvas.getBoundingClientRect();
        return {
            x: (e.clientX - r.left) * (canvas.width / (r.width || 1)),
            y: (e.clientY - r.top) * (canvas.height / (r.height || 1))
        };
    }

    function start(e) {
        drawing = true;
        const p = pos(e);
        ctx.beginPath();
        ctx.moveTo(p.x, p.y);
        // A single tap should leave a dot, not nothing.
        ctx.lineTo(p.x + 0.01, p.y + 0.01);
        ctx.stroke();
        inked = true;
        track(p);
        if (canvas.setPointerCapture && e.pointerId !== undefined) {
            try {
                canvas.setPointerCapture(e.pointerId);
            } catch (err) {
                /* capture is a nicety; strokes still work without it */
            }
        }
        if (e.cancelable) e.preventDefault();
    }

    function move(e) {
        if (!drawing) return;
        const p = pos(e);
        ctx.lineTo(p.x, p.y);
        ctx.stroke();
        inked = true;
        track(p);
        if (e.cancelable) e.preventDefault();
    }

    function end() {
        if (!drawing) return;
        drawing = false;
        if (typeof onChange === 'function') onChange();
    }

    canvas.addEventListener('pointerdown', start);
    canvas.addEventListener('pointermove', move);
    canvas.addEventListener('pointerup', end);
    canvas.addEventListener('pointercancel', end);
    canvas.addEventListener('pointerleave', end);
    configure(1);

    return {
        /** Size the backing store to the displayed size at device-pixel density. Clears the pad. */
        resize() {
            const rect = canvas.getBoundingClientRect();
            if (!rect.width || !rect.height) return;
            const ratio = Math.min(window.devicePixelRatio || 1, 3);
            canvas.width = Math.ceil(rect.width * ratio);
            canvas.height = Math.ceil(rect.height * ratio);
            configure(ratio);
            inked = false;
            bounds = null;
        },
        clear() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            inked = false;
            bounds = null;
            if (typeof onChange === 'function') onChange();
        },
        hasInk() {
            return inked;
        },
        /**
         * PNG data URL of just the ink: cropped, centered on a transparent canvas of the original pad's
         * aspect (see PAD_ASPECT), and width-capped.
         */
        toPng() {
            if (!bounds) return canvas.toDataURL('image/png');
            const { sx, sy, sw, sh } = cropRect(bounds, ctx.lineWidth * 2, canvas.width, canvas.height);
            const { cw, ch, ox, oy } = fitAspect(sw, sh);
            const { dw, dh } = fitWidth(cw, ch, EXPORT_MAX_WIDTH);
            const k = dw / cw;
            const out = document.createElement('canvas');
            out.width = dw;
            out.height = dh;
            out.getContext('2d').drawImage(canvas, sx, sy, sw, sh, ox * k, oy * k, sw * k, sh * k);
            return out.toDataURL('image/png');
        }
    };
}
