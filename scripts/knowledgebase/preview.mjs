#!/usr/bin/env node
import http from 'node:http';
import { createReadStream } from 'node:fs';
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
    '.pdf': 'application/pdf',
    '.mp4': 'video/mp4',
    '.vtt': 'text/vtt',
    '.xml': 'text/plain',
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
            else if (/^\/demos\/[\w.-]+$/.test(pathname)) file = path.join(root, 'docs', pathname);
            else if (pathname.startsWith('/source/')) {
                const relative = pathname.slice('/source/'.length);
                file = path.resolve(root, relative);
                if (file !== path.join(root, 'UserGuide.md') && !file.startsWith(path.join(root, 'docs') + path.sep))
                    throw new Error('Not a preview source');
            } else {
                file = path.resolve(staticRoot, '.' + pathname);
                if (!file.startsWith(staticRoot + path.sep)) throw new Error('Invalid path');
            }
            if (path.extname(file) === '.mp4') {
                const { size } = await fs.stat(file);
                const range = request.headers.range;
                const match = range && /^bytes=(\d+)-(\d*)$/.exec(range);
                const start = match ? Number(match[1]) : 0;
                const end = match && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
                if ((range && !match) || start > end || start >= size) {
                    response.writeHead(416, { 'Content-Range': `bytes */${size}` }).end();
                    return;
                }
                response.writeHead(match ? 206 : 200, {
                    'Accept-Ranges': 'bytes',
                    'Content-Type': 'video/mp4',
                    'Content-Length': end - start + 1,
                    ...(match && { 'Content-Range': `bytes ${start}-${end}/${size}` })
                });
                if (request.method === 'HEAD') response.end();
                else {
                    const stream = createReadStream(file, { start, end });
                    response.on('close', () => stream.destroy());
                    stream.pipe(response);
                }
                return;
            }
            let content = await fs.readFile(file);
            const address = `http://127.0.0.1:${server.address().port}`;
            if (file === path.join(root, 'docs/knowledgebase/catalog.json')) {
                // Preview unpublished downloads alongside the local articles.
                content = Buffer.from(
                    content
                        .toString()
                        .replaceAll(
                            /https:\/\/github\.com\/Portwood-Global-Solutions\/Portwood\/blob\/main\/(docs\/|UserGuide\.md)/g,
                            address + '/source/$1'
                        )
                        .replaceAll('https://portwood.dev/demos/', address + '/demos/')
                );
            }
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
            response.writeHead(200, {
                'Content-Type': pathname.startsWith('/source/docs/knowledgebase/examples/') && file.endsWith('.html')
                    ? 'text/plain; charset=utf-8'
                    : mime[path.extname(file)] || 'application/octet-stream',
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
