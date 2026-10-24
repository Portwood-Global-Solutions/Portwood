#!/usr/bin/env node
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const mime = {
    '.html': 'text/html',
    '.js': 'text/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.md': 'text/plain',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff2': 'font/woff2',
    '.webm': 'video/webm'
};

export async function startPreview({ website = path.join(root, 'website'), port = 4173 } = {}) {
    const staticRoot = path.resolve(website, 'static-site');
    const server = http.createServer(async (request, response) => {
        try {
            const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
            let file;
            if (pathname === '/' || pathname === '/guide' || pathname === '/guide.html')
                file = path.join(staticRoot, 'guide.html');
            else if (pathname.startsWith('/source/')) {
                const relative = pathname.slice('/source/'.length);
                if (
                    !(
                        relative === 'UserGuide.md' ||
                        relative.startsWith('docs/knowledgebase/') ||
                        relative.startsWith('docs/reference/') ||
                        relative.startsWith('docs/images/')
                    )
                )
                    throw new Error('Not a preview source');
                file = path.resolve(root, relative);
                if (!file.startsWith(root + path.sep)) throw new Error('Invalid path');
            } else {
                file = path.resolve(staticRoot, '.' + pathname);
                if (!file.startsWith(staticRoot + path.sep)) throw new Error('Invalid path');
            }
            let content = await fs.readFile(file);
            const address = `http://127.0.0.1:${server.address().port}`;
            if (file === path.join(staticRoot, 'guide.html')) {
                content = Buffer.from(
                    content
                        .toString()
                        .replace(
                            /data-catalog="[^"]*"/,
                            `data-catalog="${address}/source/docs/knowledgebase/catalog.json"`
                        )
                        .replace(/data-source-base="[^"]*"/, `data-source-base="${address}/source/"`)
                );
            }
            if (file === path.join(root, 'docs/knowledgebase/catalog.json')) {
                content = Buffer.from(
                    content
                        .toString()
                        .replaceAll(
                            'https://github.com/Portwood-Global-Solutions/Portwood/blob/main/',
                            `${address}/source/`
                        )
                );
            }
            response.writeHead(200, {
                'Content-Type': mime[path.extname(file)] || 'application/octet-stream',
                'Cache-Control': 'no-store'
            });
            response.end(content);
        } catch (_) {
            response.writeHead(404);
            response.end('Not found');
        }
    });
    await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
    return { server, url: `http://127.0.0.1:${server.address().port}/guide` };
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
    const args = process.argv.slice(2);
    const value = (flag, fallback) => (args.includes(flag) ? args[args.indexOf(flag) + 1] : fallback);
    const { url } = await startPreview({
        website: value('--website', path.join(root, 'website')),
        port: Number(value('--port', '4173'))
    });
    console.log(`Knowledgebase preview: ${url}`);
}
