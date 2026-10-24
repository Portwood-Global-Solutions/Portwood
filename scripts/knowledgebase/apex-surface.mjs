import fs from 'node:fs';
import path from 'node:path';

// Inventory declarations, not implementation bodies. This intentionally fails the
// freshness check when an exported signature changes or a global type is added.
export function apexSurface(root) {
    const folders = ['force-app/main/default/classes', 'agentforce-ext/main/default/classes'];
    const types = [];
    for (const folder of folders) {
        for (const name of fs
            .readdirSync(path.join(root, folder))
            .filter((n) => n.endsWith('.cls'))
            .sort()) {
            const file = `${folder}/${name}`;
            const text = fs
                .readFileSync(path.join(root, file), 'utf8')
                .replace(/\/\*[\s\S]*?\*\//g, '')
                .replace(/\/\/[^\n]*/g, '');
            if (!/^\s*global\s+(?:(?:with|without|inherited)\s+sharing\s+)?(?:class|interface)\s+/m.test(text))
                continue;
            const declarations = [...text.matchAll(/^\s*global\s+([^;{}]+?)(?=[;{])/gm)].map(
                (m) => `global ${m[1].trim().replace(/\s+/g, ' ')}`
            );
            if (/global\s+interface\s+/.test(text)) {
                declarations.push(
                    ...[...text.matchAll(/^\s*([\w<>, ]+\s+\w+\([^;{}]*\))\s*;/gm)].map((m) =>
                        m[1].trim().replace(/\s+/g, ' ')
                    )
                );
            }
            types.push({
                name: name.replace(/\.cls$/, ''),
                package: folder.startsWith('agentforce-ext') ? 'Optional Agentforce extension' : 'Core',
                file,
                declarations
            });
        }
    }
    const markdown = types
        .map(
            (type) =>
                `#### ${type.name}\n\n${type.package} · [Source](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/${type.file})\n\n\`\`\`apex\n${type.declarations.join('\n')}\n\`\`\``
        )
        .join('\n\n');
    return { types, markdown };
}
