# BudgetTracker — Deployment Pipeline

Container + CI/CD artefak untuk **FinanceFlow / BudgetTracker**, aplikasi budget
tracker single-file (HTML + CSS + JS, tanpa build step, data di `localStorage`).

Aplikasinya statis, jadi seluruh pipeline ini berbiaya **Rp0**: GitHub Actions
gratis untuk repo publik, dan image-nya dipublikasikan ke GitHub Container
Registry (ghcr.io) yang juga gratis di tier publik.

## Isi

| File | Fungsi |
|---|---|
| `public/index.html` | aplikasinya (salinan dari `BudgetTracker/BudgetTrackerWebApp.html`) |
| `Dockerfile` | nginx non-root (`nginx-unprivileged`, UID 101, port 8080) |
| `nginx.conf` | server block: SPA fallback, `/healthz`, security header, gzip |
| `docker-compose.yml` | menjalankan container secara lokal, read-only filesystem |
| `tests/smoke.sh` | 5 pengecekan HTTP terhadap container yang sudah jalan |
| `.github/workflows/ci.yml` | build → jalankan → smoke test → push ke GHCR (hanya `main`) |

## Jalankan lokal

```bash
docker compose up --build
# lalu buka http://localhost:8080
```

Smoke test terhadap container yang sedang jalan:

```bash
bash tests/smoke.sh
```

Tanpa compose:

```bash
docker build -t budgettracker:local .
docker run --rm -p 8080:8080 budgettracker:local
```

## Keputusan desain

**Base image `nginxinc/nginx-unprivileged` bukan `nginx`.** Image nginx resmi
menjalankan proses master sebagai root. Varian unprivileged jalan sebagai UID
101 dan listen di 8080, jadi container tidak perlu root sama sekali —
`read_only: true` + `no-new-privileges` di compose bisa dipakai langsung.

**Tidak ada Content-Security-Policy.** Aplikasinya memuat Chart.js dari jsdelivr
dan Tesseract.js dari unpkg; Tesseract juga menarik worker (`blob:`), wasm core,
dan file bahasa saat runtime. CSP yang cukup ketat untuk berguna akan mematikan
fitur scan struk. Kalau CSP dibutuhkan, vendor kedua library itu ke `public/`
dulu, baru tambahkan header di `nginx.conf`.

**`index.html` di-set `no-cache`.** Kalau tidak, user tetap membuka versi lama
setelah deploy karena browser meng-cache satu-satunya file yang ada.

**Push hanya dari `main`.** Job publish di-guard `github.ref` — PR dari fork
tidak punya akses tulis ke registry, dan tidak semestinya punya.

## Catatan verifikasi

Semua file di sini masih **belum pernah di-build** karena Docker tidak
terpasang di mesin ini (`docker: command not found`). Yang sudah diverifikasi:
YAML `ci.yml` dan `docker-compose.yml` valid secara sintaksis, `tests/smoke.sh`
lolos `bash -n`, dan `public/index.html` identik dengan sumbernya. Langkah
pertama setelah Docker tersedia: `docker compose up --build`, lalu
`bash tests/smoke.sh`.

## Rencana lanjutan: pipeline end-to-end

Pipeline di repo ini masih **CI saja** — berhenti setelah image ter-push ke
registry. Belum ada deploy ke lingkungan hidup, verifikasi pasca-deploy, maupun
rollback otomatis. Rancangan untuk melengkapinya (target GitHub Pages, 10 stage,
9 gate, semuanya gratis) ada di [docs/PIPELINE-SPEC.md](docs/PIPELINE-SPEC.md).

## Deploy ke hosting

Image-nya static nginx biasa, jadi bisa dijalankan di mana pun ada Docker:
Fly.io / Railway / Oracle Cloud free tier, atau VPS murah (Rp40–70rb/bulan).
Setelah CI berjalan, image tersedia di:

```
ghcr.io/<user>/<repo>:latest
```

Untuk hosting statis murni (GitHub Pages, Cloudflare Pages, Netlify) container
ini tidak diperlukan — cukup serve `public/`. Container berguna kalau targetnya
VPS/orkestrator, atau kalau nanti butuh reverse proxy dan header konsisten.
