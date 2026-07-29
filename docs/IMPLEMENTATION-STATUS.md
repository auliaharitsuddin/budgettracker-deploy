# Status Implementasi terhadap PIPELINE-SPEC.md

Ringkasan apa yang sudah dikerjakan, apa yang menyimpang dari spec dan kenapa,
serta apa yang masih perlu tangan manusia.

---

## 1. File yang dibuat

| File | Stage | Fungsi |
|---|---|---|
| `tests/smoke.sh` (ditulis ulang) | 3, 7 | 11 assertion, dua mode target (`container` / `pages`) |
| `tests/pages_sim.py` | — | Simulator perilaku GitHub Pages untuk menguji mode `pages` secara lokal |
| `tests/e2e/budgettracker.spec.js` | 4, 7 | 10 skenario Playwright |
| `playwright.config.js`, `package.json` | 4 | Target diarahkan lewat `PLAYWRIGHT_BASE_URL` |
| `scripts/prepare-pages-artifact.sh` | 6 | Injeksi build marker + `404.html` |
| `.yamllint.yml` | 1.3 | Konfigurasi yamllint |
| `.github/workflows/_test-suite.yml` | 1–4 | Reusable, dipakai `ci.yml` dan `release.yml` |
| `.github/workflows/_deploy-and-verify.yml` | 6–7 | Reusable, dipakai rilis dan rollback |
| `.github/workflows/_rollback.yml` | 9 | Reusable, dipakai otomatis dan manual |
| `.github/workflows/ci.yml` | 1–4 | PR + branch non-main |
| `.github/workflows/release.yml` | 1–9 | Push ke `main` |
| `.github/workflows/rollback.yml` | 9 | Dispatch manual |
| `.github/workflows/monitor.yml` | 10 | Cron tiap 30 menit |
| `.github/workflows/deploy-container.yml` | 15 | Jalur Render opsional |

Tiga workflow berawalan `_` adalah reusable workflow. Ini keputusan penting:
**rollback memakai jalur deploy-and-verify yang persis sama dengan rilis
normal.** Kalau rollback punya logika deploy sendiri, jalur itu hanya
teruji saat insiden — justru saat paling tidak boleh gagal.

---

## 2. Empat bug nyata yang ditemukan saat implementasi

Ini bukan penyesuaian kosmetik; keempatnya akan merusak pipeline di produksi.

### 2.1 `smoke.sh` mati oleh SIGPIPE (bug di versi lama)

Pola `echo "$home" | grep -q "FinanceFlow"` di bawah `set -o pipefail`:
`grep -q` keluar begitu menemukan kecocokan, menutup pipe selagi `echo` masih
menulis. `echo` kena SIGPIPE, pipeline melaporkan 141, dan `set -e`
menghentikan seluruh script di tengah jalan.

Efeknya jahat karena **bergantung ukuran**: file kecil lolos, file besar
(`index.html` 2259 baris) gagal. Bug ini sudah ada sejak versi pertama
`smoke.sh` dan tidak pernah terlihat karena script itu belum pernah
dijalankan terhadap server yang benar-benar menyajikan aplikasinya —
sebelumnya hanya diuji terhadap port kosong.

Perbaikan: fungsi `contains()` memakai pattern matching shell, tanpa
subprocess, jadi tidak ada pipe yang bisa putus.

### 2.2 GitHub Pages menyajikan `404.html` dengan status 404, bukan 200

Spec (Stage 7.3) mengasumsikan assertion SPA-fallback sama untuk kedua
target. Kenyataannya:

- container: `try_files ... /index.html` → status **200**
- Pages: menyajikan `404.html` → status **404**, dan ini tidak bisa dikonfigurasi

Assertion `code == 200` akan gagal di **setiap** rilis, memicu rollback
palsu terus-menerus. Perbaikan: mode `pages` memeriksa isi body (app shell
tetap termuat, router sisi klien mengambil alih), mode `container` tetap
memeriksa status 200.

### 2.3 Drift check di monitor akan alarm palsu tiap deploy

Rilis melakukan deploy **sebelum** memindahkan tag `last-good` — tag baru
bergerak setelah Stage 7 lolos. Jadi selama jendela rilis, marker di
produksi sah-sah saja berbeda dari `last-good`.

Perbaikan: monitor menerima marker yang cocok dengan `last-good` **atau**
HEAD `main`. Selain itu berarti benar-benar ada yang deploy di luar pipeline.

### 2.4 URL Pages tidak boleh ditebak dari nama repo

Menyusun `https://<owner>.github.io/<repo>/` salah untuk user/org site
(repo bernama `<owner>.github.io`), yang disajikan di apex tanpa segmen
path. Monitor akan memantau URL 404 selamanya tanpa ada yang sadar.

Perbaikan: ambil `html_url` dari `gh api repos/{owner}/{repo}/pages`.

---

## 3. Penyimpangan dari spec (disengaja)

| Spec | Implementasi | Alasan |
|---|---|---|
| Stage 6: `environment: production` | `environment: github-pages` | `actions/deploy-pages` mewajibkan nama environment ini; spec keliru |
| Stage 7.3: assertion sama untuk kedua target | Beda per target | Lihat 2.2 di atas |
| Stage 1.8: deploybot drift check | Dibuat opsional, aktif hanya jika repo variable `DEPLOYBOT_REPO` diisi, dan `continue-on-error` | deploybot ada di repo terpisah; tool lintas-repo tidak boleh memblokir rilis repo ini |
| Stage 4.9: no horizontal scroll | Ditandai `test.fail()` | Menemukan bug CSS nyata di aplikasi — lihat bagian 4 |
| Stage 2: build lalu publish | Image di-build **sekali**, diekspor sebagai artifact, dipakai ulang Stage 3–5 | Build ulang saat publish akan menerbitkan artefak yang tidak pernah diuji |
| — | `--failure-threshold warning` pada hadolint | Default hadolint adalah `info`, yang menggagalkan build karena catatan gaya |

---

## 4. Bug aplikasi yang ditemukan test 4.9

`#main` melebar ke **526px** pada viewport 375px, menyebabkan scroll
horizontal di mobile.

Penyebab: `#main` adalah flex child dengan `min-width: auto` bawaan (menolak
mengecil di bawah lebar kontennya), dan `.cards-grid` tetap memakai
`minmax(200px, 1fr)` di dalam `@media (max-width: 768px)`.

Perbaikan di `public/index.html`:

```css
#main { min-width: 0; }                       /* biarkan flex child mengecil */
@media (max-width: 768px) {
  .cards-grid { grid-template-columns: 1fr; } /* satu kolom di mobile */
}
```

**Saya tidak menerapkannya** karena `public/index.html` sengaja dijaga
byte-identical dengan `BudgetTracker/BudgetTrackerWebApp.html` (lihat
README) — memperbaikinya di sini akan memutus hubungan itu tanpa
sepengetahuanmu. Perbaikan semestinya masuk ke repo BudgetTracker dulu.

Sementara itu test ditandai `test.fail()`: suite tetap hijau selama bug
terbuka, dan akan **merah begitu CSS-nya diperbaiki** — sinyal untuk
menghapus baris `test.fail()`. Ini disengaja: bug tetap terlihat, bukan
dihapus diam-diam bersama assertion yang menemukannya.

---

## 5. Yang sudah diverifikasi vs belum

### Sudah dijalankan dan lolos

| Pemeriksaan | Hasil |
|---|---|
| `actionlint` (binary asli v1.7.7) terhadap 8 workflow | 0 temuan |
| `yamllint` terhadap semua YAML | 0 warning |
| `shellcheck` v0.10.0 terhadap `smoke.sh` + `scripts/*.sh` | 0 temuan (setelah perbaikan SC2319) |
| Playwright 10 skenario terhadap aplikasi sungguhan | 10 lolos (4.9 sebagai expected failure) |
| `smoke.sh --target=pages` terhadap simulator Pages | lolos saat marker cocok, gagal saat stale |
| `smoke.sh --target=container` terhadap server non-nginx | gagal di semua assertion khusus nginx (benar) |
| `prepare-pages-artifact.sh` | marker terinjeksi, `404.html` identik, `public/` tidak tersentuh |

### Belum bisa diverifikasi di mesin ini

| Hal | Kenapa |
|---|---|
| `docker build`, ukuran image, Trivy, SBOM | **Docker tidak terpasang** (`docker: command not found`) |
| Assertion Stage 3.5–3.9 (non-root, HEALTHCHECK, crash-loop, read-only) | butuh container hidup |
| Seluruh eksekusi workflow di GitHub Actions | butuh repo remote |
| Deploy Pages, Stage 7, rollback | butuh repo remote + Pages aktif |
| `hadolint`, `gitleaks`, `tidy`, `nginx -t` | dijalankan lewat Docker di CI |

Artinya: **logika, sintaks, dan semua jalur yang bisa dijalankan tanpa
Docker sudah terbukti.** Perilaku container dan perilaku GitHub Actions
masih berupa desain yang beralasan, belum fakta terverifikasi.

---

## 6. Langkah manual yang tersisa (Stage 0)

Repo git lokal **sudah** dibuat (`git init`, branch `main`, satu commit).
Sisanya butuh keputusanmu karena menyangkut akun dan visibilitas:

```bash
cd "Downloads/Proyek Independen/budgettracker-deploy"

# 1. Buat repo publik dan push. Publik itu wajib: Pages, Actions tanpa
#    batas menit, dan required-reviewer di environment semuanya gratis
#    hanya untuk repo publik.
gh repo create budgettracker-deploy --public --source=. --push

# 2. Aktifkan Pages dengan sumber GitHub Actions
gh api -X POST repos/{owner}/budgettracker-deploy/pages -f build_type=workflow

# 3. Branch protection: wajibkan check test-suite hijau sebelum merge
#    (lewat UI: Settings -> Branches -> Add rule -> Require status checks)

# 4. Opsional, aktifkan gate drift deploybot:
gh variable set DEPLOYBOT_REPO --body "<owner>/deploybot"

# 5. Opsional, jalur container Render:
gh secret set RENDER_DEPLOY_HOOK --body "<deploy hook url>"
gh variable set RENDER_SERVICE_URL --body "https://<service>.onrender.com"
```

**Sebelum push, pastikan ini benar:** repo ini akan publik. Aman untuk
BudgetTracker karena seluruh datanya ada di `localStorage` browser, tidak
ada satu pun di repo. **Jangan pakai pola ini untuk SiPENA** — ada PII asli
di `natriumdb.db`.

---

## 7. Uji penerimaan (langkah 10 di spec)

Pipeline yang belum pernah gagal-lalu-pulih hanya berteori soal rollback.
Setelah rilis pertama hijau dan tag `last-good` terbentuk:

```bash
git checkout -b break-it
# rusak app shell supaya Stage 7 gagal tapi build tetap sukses:
sed -i 's/FinanceFlow/BROKENAPP/' public/index.html
git commit -am "deliberately break the app shell" && git push
# merge ke main, lalu amati:
```

Yang seharusnya terjadi: Stage 1–6 lolos, Stage 7 gagal di assertion app
shell, Stage 9 otomatis men-deploy ulang `last-good`, memverifikasinya, dan
membuka issue berlabel `incident`. Tag `last-good` **tidak** bergerak.

Kalau itu terjadi, pipeline-nya nyata. Kalau tidak, ada yang perlu
diperbaiki sebelum ini bisa disebut end-to-end.
