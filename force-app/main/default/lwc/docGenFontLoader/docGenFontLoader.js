/** Load the exact Salesforce File version without routing font bytes through Apex. */
const loaded = new Map();
/** The same complete, unfiltered menu in every document editor. */
export function fontPickerOptions(builtins, faces = []) {
    const weights = {
        100: 'Thin',
        200: 'Extra light',
        300: 'Light',
        400: 'Regular',
        500: 'Medium',
        600: 'Semibold',
        700: 'Bold',
        800: 'Extra bold',
        900: 'Black'
    };
    return [
        ...builtins.map((font) => ({ ...font, fontFamily: font.value, detail: 'Built-in' })),
        ...faces
            .filter((face) => face.selectable)
            .map((face) => ({
                label: face.label,
                value: 'face:' + face.key,
                fontFace: face,
                detail: [weights[face.weight] || face.weight, face.style === 'italic' ? 'Italic' : '']
                    .filter(Boolean)
                    .join(' ')
            }))
    ];
}
export function loadFontFace(face) {
    if (!face?.previewUrl || !face?.previewFamily) return Promise.resolve();
    if (!/^\/sfc\/dist\/version\/download\//.test(face.previewUrl) || /[\\\r\n]/.test(face.previewUrl))
        return Promise.reject(new Error('Font previews must use Salesforce Files.'));
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
