# BudgetTracker — Deployment Pipeline

Container + CI/CD artefak untuk **FinanceFlow / BudgetTracker**, aplikasi budget
tracker single-file (HTML + CSS + JS, tanpa build step, data di `localStorage`).

Aplikasinya statis, jadi seluruh pipeline ini berbiaya **Rp0**: GitHub Actions
gratis untuk repo publik, dan image-nya dipublikasikan ke GitHub Container
Registry (ghcr.io) yang juga gratis di tier publik.

## Isi

| File | Fungsi |
|---|---|
| `public/index.html` | aplikasinya (salinan byte-identical dari `BudgetTracker/BudgetTrackerWebApp.html`) |
| `Dockerfile` | nginx non-root (`nginx-unprivileged`, UID 101, port 8080) |
| `nginx.conf` | server block: SPA fallback, `/healthz`, security header, gzip |
| `docker-compose.yml` | menjalankan container lokal, read-only filesystem |
| `tests/smoke.sh` | 11 assertion HTTP, dua mode: `--target=container` / `--target=pages` |
| `tests/e2e/` | 10 skenario Playwright (transaksi, persistensi, budget, tema, i18n) |
| `tests/pages_sim.py` | simulator GitHub Pages untuk menguji mode `pages` tanpa deploy |
| `scripts/prepare-pages-artifact.sh` | injeksi build marker + `404.html` untuk SPA fallback di Pages |
| `.github/workflows/` | 8 workflow: Stage 1–10 (lihat tabel di bawah) |

### Workflow

| File | Trigger | Stage |
|---|---|---|
| `ci.yml` | PR, push non-main | 1–4 |
| `release.yml` | push ke `main` | 1–9 |
| `rollback.yml` | manual | 9 |
| `monitor.yml` | cron 30 menit | 10 |
| `deploy-container.yml` | manual | jalur Render opsional |
| `_test-suite.yml`, `_deploy-and-verify.yml`, `_rollback.yml` | reusable | dipakai bersama oleh yang di atas |

Rollback memakai jalur deploy-and-verify yang **persis sama** dengan rilis
normal. Kalau rollback punya logika deploy sendiri, jalur itu cuma teruji
saat insiden — justru saat paling tidak boleh gagal.

## Jalankan lokal

```bash
docker compose up --build          # lalu buka http://localhost:8080
bash tests/smoke.sh                # smoke test terhadap container

# Test browser terhadap container yang sedang jalan
npm ci && npx playwright install chromium
PLAYWRIGHT_BASE_URL=http://localhost:8080 npx playwright test
```

Menguji jalur Pages tanpa deploy (tidak butuh Docker):

```bash
bash scripts/prepare-pages-artifact.sh testsha dist
python tests/pages_sim.py dist 8097 &
bash tests/smoke.sh http://localhost:8097 --target=pages --marker=testsha
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

## Pipeline end-to-end

Rancangannya di [docs/PIPELINE-SPEC.md](docs/PIPELINE-SPEC.md); status
implementasi, penyimpangan dari spec, dan bug yang ditemukan sepanjang
pengerjaan ada di [docs/IMPLEMENTATION-STATUS.md](docs/IMPLEMENTATION-STATUS.md).

Semua workflow sudah ditulis dan lolos `actionlint`, `yamllint`, dan
`shellcheck`; Playwright 10/10 hijau terhadap aplikasi sungguhan. Yang
**belum** terverifikasi: semua yang butuh Docker (build image, Trivy, assertion
hardening container) dan semua yang butuh repo remote (eksekusi Actions, deploy
Pages, rollback). Docker tidak terpasang di mesin tempat ini dikerjakan.

Langkah manual yang tersisa sebelum pipeline benar-benar hidup ada di
[bagian 6 IMPLEMENTATION-STATUS](docs/IMPLEMENTATION-STATUS.md#6-langkah-manual-yang-tersisa-stage-0).

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
