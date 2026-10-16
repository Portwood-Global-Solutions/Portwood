/** Load the exact Salesforce File version without routing font bytes through Apex. */
const loaded = new Map();
export function loadFontFace(face) {
    if (!face?.previewUrl || !face?.previewFamily) return Promise.resolve();
    if (!loaded.has(face.key)) {
        const promise = (async () => {
            const response = await fetch(face.previewUrl, { credentials: 'include' });
            if (!response.ok) throw new Error('Font File download failed (' + response.status + ').');
            const font = new FontFace(face.previewFamily, await response.arrayBuffer(), {
                weight: String(face.weight),
                style: face.style
            });
            await font.load();
            document.fonts.add(font);
        })();
        loaded.set(face.key, promise);
        promise.catch(() => loaded.delete(face.key));
    }
    return loaded.get(face.key);
}
