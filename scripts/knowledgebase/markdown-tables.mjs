// GFM treats pipes inside inline code as column delimiters unless escaped.
// Check intended table structure before formatting/rendering can hide the mistake.
export function markdownTables(markdown) {
    const tables = [];
    const errors = [];
    let block = [];
    let fence = null;
    const cells = (line) => {
        const text = line.trim();
        const values = [];
        let start = 0;
        for (let i = 0; i < text.length; i++) {
            if (text[i] === '\\') {
                i++;
            } else if (text[i] === '|') {
                values.push(text.slice(start, i).trim());
                start = i + 1;
            }
        }
        values.push(text.slice(start).trim());
        if (text.startsWith('|')) values.shift();
        if (start === text.length) values.pop();
        return values;
    };
    const finish = () => {
        if (block.length >= 2) {
            const rows = block.map(({ text }) => cells(text));
            const columns = rows[0].length;
            if (!rows[1].every((cell) => /^:?-+:?$/.test(cell))) {
                errors.push(`Line ${block[1].line}: expected a table delimiter after the header.`);
            } else {
                for (let i = 1; i < rows.length; i++) {
                    if (rows[i].length !== columns)
                        errors.push(
                            `Line ${block[i].line}: table has ${rows[i].length} columns; header has ${columns}. Escape literal pipes as \\|, including inside inline code.`
                        );
                }
                tables.push({ line: block[0].line, columns, rows: rows.length - 2 });
            }
        }
        block = [];
    };
    markdown.split(/\r?\n/).forEach((line, index) => {
        const marker = line.match(/^\s*(`{3,}|~{3,})/);
        if (marker) {
            finish();
            if (!fence) fence = marker[1];
            else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
        } else if (!fence && /^\s*\|/.test(line)) {
            block.push({ text: line, line: index + 1 });
        } else {
            finish();
        }
    });
    finish();
    return { tables, errors };
}
