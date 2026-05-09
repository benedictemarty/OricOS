# CHANGELOG - OricOS

All notable changes to the OricOS kernel project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.30.0] - 2026-05-09

### Sprint 3.b v0.2 partiel — kernel_fill_rect_aligned (bug d'offset)

#### Added
- **`kernel_fill_rect_aligned`** : rectangle 8-px-aligned X (groupes
  de 8 pixels). Args ZP : gx_start, gx_count, y_start, y_count, color.
- Algorithme : pour chaque ligne (count-down 8-bit en zp $3B),
  inner loop écrit gx_count triples consécutifs via DP indirect long
  [HIRES2_FB_PTR],Y avec Y 16-bit.
- Constantes : HIRES2_BPL=90, HIRES2_GX_START..RECT_COL en zp $40-$44.

#### ⚠️ Bug connu (à débugger v0.2.1)
- Symptôme : rectangle dessiné à (-6gx, -51y) du target. Size correcte
  (800 triples pour 10×80) mais placement faux.
- Calcul `y_start × 90 + gx_start × 3` semble correct en review listing
  asm (kernel.lst), mais en pratique l'écriture commence à offset 822
  au lieu de 5430 (pour y=60, gx=10).
- Differential = 4608 = 0x1200 = 18 × 256. Suggère un bug high byte
  de FB_PTR.
- **Appel au boot retiré** pour ne pas casser le test
  `test_oricos_hires2_clear_fills_blue` (qui passe en v0.1).
- Reprendre avec asm sentinels (sta zone bank 1 connue) + lecture
  post-STP pour tracer les valeurs intermédiaires.

#### Validation v0.1 préservée
- 515 tests OK (état Sprint 3.b v0.1 inchangé).
- `kernel_hires2_clear(blue)` au boot continue à remplir bank 128.

#### Reportés v0.3
- `kernel_pixel_set(x, y, color)` arbitraire pixel-perfect.
- `kernel_blit(src, dst, w, h)` pour fontes / icônes.
- Bascule mode TEXT ↔ HIRES via registre I/O `VID_MODE`.

---

## [0.29.0] - 2026-05-09

### Sprint 3.b v0.1 — Kernel primitive HIRES Oric 2 (clear_screen) ✨

#### Added
- **`kernel_hires2_clear(A=color)`** : remplit le framebuffer HIRES
  Oric 2 (bank 128, ADR-12) avec une couleur uniforme 0..7. 18 000
  octets écrits via DP indirect long (3 octets par groupe de 8 pixels).
- **`pattern_table`** : 8 entries × 3 octets, pré-calcul du pattern
  24-bit `color × $249249` (8 pixels même couleur).
- Constantes `HIRES2_BANK = $80`, `HIRES2_FB_SIZE = 18000`.
- ZP tmp : `HIRES2_PAT_PTR ($20)`, `HIRES2_FB_PTR ($24)`,
  `HIRES2_PB0..PB2 ($34..$36)`.
- **Boot kernel intégré** : appel `kernel_hires2_clear(blue)` tôt dans
  `kernel_entry` (après bascule mode N, avant sentinel). Lazy alloc
  bank 128 via 1ère écriture (mécanisme B1.8 Phosphoric).

#### Validation (côté Phosphoric)
- 515 tests OK (514 → 515, +1).
- Test `test_oricos_hires2_clear_fills_blue` :
  - Boot kernel → ASSERT pattern octets `$92 $49 $24` aux 4 coins
    + dernier triple (offset 17997-17999).
  - ASSERT `hires_oric2_get_pixel = 4` (blue) sur 5 positions.
  - ASSERT 100% des pixels ARGB = `0x0000FF` (= scan complet 240×200).

#### Reportés Sprint 3.b v0.2
- `kernel_pixel_set(x, y, color)` arbitraire pixel-perfect
  (gestion bit_shift cross-octet pour pixels 2 et 5).
- `kernel_fill_rect(x, y, w, h, color)` arbitraire.
- `kernel_blit(src, dst, w, h)` pour rendering de fontes / icônes.
- Bascule mode TEXT Oric 1 ↔ HIRES Oric 2 (registre I/O `VID_MODE`).

#### Importance architecturale
**Premier code OricOS qui écrit dans le framebuffer Oric 2.** Le pipeline
complet est désormais opérationnel : kernel asm → bank 128 → render
ARGB → ASSERT visuel. Les futurs sprints 3.c/d/e (window manager,
toolkit, multifenêtré) pourront s'appuyer sur des primitives de plus
haut niveau (fill_rect, blit) construites sur ce socle.

---

## [0.28.0] - 2026-05-09

### Sprint 2.l v0.2 — App loader multi-cluster depuis SD ✨

#### Added
- **Boot kernel intégré** : ouvre MULTI.BIN (bundle 527B, 2 clusters)
  via `kernel_fat_open`, charge le fichier complet vers $01:8000 via
  `kernel_fat_read_file`, puis exécute via `kernel_app_exec`.
- **App MULTI.BIN** : bundle dont la section CODE est à offset 520
  (= dans le 2e cluster). Exerce le pipeline cross-cluster :
  - Header bundle dans cluster 6 (LBA 164).
  - Code app à offset 520 = dans cluster 7 (LBA 165).
  - `kernel_app_exec` calcule `DP_SRC = DP_PTR + offset` (16-bit add)
    puis copie 7 octets vers `$BANK:0200`.
- L'app exécute `ldx #'X' ; lda #1 ; cop #$AA ; rtl` → 'X' à $BBAD.

#### Validation
- 503 tests OK (`kernel_app_exec` v0.1 supporte déjà bundle multi-cluster
  en RAM ; aucune modification de l'API).
- Image SD test : 166 secteurs (FAT étendue avec FAT[6]=7, FAT[7]=EOC ;
  3e entry root dir MULTI.BIN cluster=6 size=527).
- ASSERT `mem[$BBAD] = 'X'` après boot kernel — confirme exec depuis
  bundle multi-cluster.
- Démo SDL2 attendue : "OricOS v0.7" + "YABZZX" (5 chars : Y syscall +
  AB hex + 2 Z = 2 apps single-cluster + X = app multi-cluster).

#### Importance architecturale
**OricOS peut désormais charger ET exécuter une app de taille arbitraire
depuis FAT32 SD**. C'est le pipeline complet :
1. fat_open (lookup 8.3)
2. fat_read_file (multi-cluster)
3. app_exec (validate + alloc bank + copy + JSL)

Aucune limite de taille pour la section CODE en RAM (l'offset 32-bit du
bundle permet section CODE > 64 KiB ; seule la limite size 8-bit dans
app_exec v0.1 borne le code copié à 256 octets — à étendre v0.3 si
besoin).

#### Reportés v0.3 / Reportés OS-2.l v0.3
- Section CODE > 256 octets (passage size 16-bit dans la copie).
- Sections multiples (DATA, ICON) traitées par app_exec.
- Free bank au RTS de l'app (resource tracking).
- Sandbox / privilege check.

---

## [0.27.0] - 2026-05-08

### Sprint 2.j v0.3 — kernel_fat_read_file (multi-cluster) ✨

#### Added
- **`kernel_fat_read_file`** : lit un fichier complet en suivant la
  chaîne FAT32 jusqu'à EOC. Boucle `read_cluster` + `next_cluster`,
  avance `DP_PCPTR` de 512 octets entre chaque cluster.
- API : input `FS_FOUND_CLUSTER` (4B, first cluster du fichier),
  `DP_PCPTR` (24-bit, destination). Préserve `FS_FOUND_CLUSTER` à la
  sortie (sauvegarde/restauration via zp tmp $28-$2B).
- Sortie sur EOC (cluster >= $0FFFFFF8) : test 4 bytes du cluster avec
  AND $0F sur byte 3 (FAT32 28 bits).
- Boot kernel intégré : ouvre BIG.BIN (1024 octets, 2 clusters) puis
  lit le fichier vers $01:7000. Cluster 4 (LBA 162, pattern $AA) +
  cluster 5 (LBA 163, pattern $55) = 1024 octets contigus en mémoire.

#### Validation
- 503 tests OK.
- Image SD test étendue : 164 secteurs (boot + zéros + FAT + root dir
  avec 2 entries + 3 clusters de données).
- ASSERTs supplémentaires :
  - `mem[$01:7000]` = $AA (début cluster 4)
  - `mem[$01:71FF]` = $AA (fin cluster 4, 512 octets exacts)
  - `mem[$01:7200]` = $55 (début cluster 5, suivi de la chaîne FAT[4]→5)
  - `mem[$01:73FF]` = $55 (fin cluster 5)

#### Reportés v0.4
- Fichiers > 64 KiB (DP_PCPTR low+mid 16-bit, propagation vers bank).
- BPS != 512.
- Cluster >= 16384 (FAT spread sur plusieurs secteurs).
- Subdirectories.

#### Importance architecturale
**OricOS peut désormais charger un fichier de taille arbitraire**
(jusqu'à 64 KiB en v0.3) depuis FAT32 SD. C'est le building block
final pour exécuter des apps réelles : un app loader complet pourra
charger un bundle multi-cluster, alloc autant de banks que nécessaire,
et exécuter. La granularité 1 cluster = 1 secteur (SPC=1) est typique
en FAT32 sur petites cartes SD.

---

## [0.26.0] - 2026-05-08

### Sprint 2.j v0.2 — kernel_fat_next_cluster (cluster chain) ✨

#### Added
- **`kernel_fat_next_cluster`** : lit l'entry FAT32 d'un cluster pour
  obtenir le cluster suivant dans la chaîne. Permet la lecture de
  fichiers > 1 cluster.
- Convention : input dans `FS_QUERY_CLUSTER` (4B, $016180..$016183),
  output dans `FS_NEXT_CLUSTER` (4B, $01617C..$01617F). Le high
  nibble du byte 3 est masqué (FAT32 = 28 bits effectifs). Une valeur
  de retour >= $0FFFFFF8 = EOC (fin de chaîne).
- Algorithme : LBA = `FS_RSC + (cluster*4) / FS_BPS`,
  `offset_in_sec = (cluster*4) % FS_BPS`. Hypothèse v0.2 : BPS=512,
  cluster < 16384 (offset_bytes 16-bit).
- Boot kernel intégré : test cluster chain avec `FS_QUERY_CLUSTER = 4`,
  vérifie `FS_NEXT_CLUSTER == 5` (FAT[4] = 5 dans l'image test).

#### Validation
- 503 tests OK (pas de nouveau test, ASSERT supplémentaire dans
  `test_oricos_fat_init_validates_fat32_signature`).
- Image SD test étendue : LBA 32 contient une vraie FAT FAT32 partielle
  avec FAT[0..5] (media descriptor + reserved + root EOC + HELLO.BIN
  EOC + BIG.BIN cluster 4 → 5 → EOC).
- ASSERT `FS_NEXT_CLUSTER = $00000005` après boot kernel.

#### Reportés v0.3
- `kernel_fat_read_file` : itération sur la chaîne complète pour
  charger un fichier > 1 cluster.
- BPS != 512.
- Cluster >= 16384 (FAT spread sur plusieurs secteurs).
- Subdirectories (parser dirs au-delà de root).

#### Importance architecturale
La traversée de chaîne FAT est un building block essentiel : sans elle,
OricOS ne peut charger que des fichiers ≤ 512 octets. Avec elle, la
v0.3 pourra charger des fichiers de taille arbitraire en bouclant sur
`fat_next_cluster` jusqu'à EOC.

---

## [0.25.0] - 2026-05-08

### Sprint 2.j.5/6 — App chargée depuis SD via FAT32 ✨

#### Added
- **`kernel_fat_read_cluster`** : lit 1 cluster (v0.1, SPC=1 = 1 secteur)
  vers `DP_PCPTR`. LBA = `FS_FDS + (FS_FOUND_CLUSTER - 2)`. Modifie A,
  X, Y, $30/$31, FS_BUFFER (transitoirement).
- **Boot kernel intégré** : après `fat_open` OK, lit le cluster du
  bundle vers `$01:6200` puis appelle `kernel_app_exec` avec ce bundle.
  L'app exécutée depuis SD écrit un 'Z' supplémentaire après le 'Z'
  du bundle inline.

#### Validation
- 503 tests OK.
- Image FAT32 test étendue : 162 secteurs (boot + zéros + root dir +
  cluster 3 = bundle hello).
- Test ASSERT après boot kernel :
  - `mem[$01:6200..]` contient le bundle ("OOS\\x01...A2 Z..6B").
  - `mem[$BBAB] = 'Z'` (bundle inline).
  - `mem[$BBAC] = 'Z'` (bundle chargé depuis SD).
- Démo SDL2 visible : "OricOS v0.7" + "YABZZ" (Y syscall + AB hex +
  **deux Z** — premier de l'app inline, second de l'app SD).

#### Importance architecturale
**Le pipeline complet est fonctionnel** :
1. Boot kernel.
2. SD device émulé (Phosphoric I/O $0320-$0327).
3. `kernel_sd_read_block` ↔ image hôte.
4. `kernel_fat_init` valide FAT32 + parse champs.
5. `kernel_fat_open` localise fichier 8.3 dans root dir.
6. `kernel_fat_read_cluster` charge le contenu en mémoire.
7. `kernel_app_exec` valide bundle + alloc bank + copy code + JSL.
8. App exécute en bank dédiée + syscall vers kernel.

**OricOS peut désormais charger et exécuter une app depuis FAT32 SD**
sans qu'elle soit embedded dans le kernel.

#### v0.2 (reportés)
- Cluster chain traversal (fichier > 1 cluster).
- Fichier > 32 MiB (LBA 32-bit).
- Subdirectories.
- Lectures partielles (offset + size).
- Cache de blocs.

---

## [0.24.0] - 2026-05-08

### Sprint 2.j.4 — kernel_fat_open (root dir lookup 8.3)

#### Added
- **`kernel_fat_open`** : recherche un fichier 11B (8.3 padded espaces,
  uppercase) dans le root dir.
  - Args : `DP+$40..$4A` = filename 11B.
  - Lit root dir cluster (LBA = `FS_FDS`, suppose `FS_ROOT=2`) dans
    `FS_BUFFER` via `kernel_sd_read_block`.
  - Scanne 16 entries de 32B :
    - skip `$00` (end of dir, → NOT_FOUND)
    - skip `$E5` (deleted)
    - skip `$0F` attribute (LFN)
    - skip `$08`/`$10` attributes (volume label, directory)
    - sinon compare nom byte-par-byte via `cmp a:DP_FILENAME,Y`
  - Sur match : extrait `first_cluster` (cluster_low+high → 4B) et
    `size` (4B) → stocke dans `FS_FOUND_CLUSTER`/`FS_FOUND_SIZE`.
  - `FS_OPEN_RESULT` = `$00` OK / `$01` NOT_FOUND.
- **Constantes `DE_*`** pour offsets dir entry, `DP_FILENAME = $40`,
  `DP_ENTRY = $50` (pointer 24-bit en zero page).

#### Validation
- 503 tests OK.
- Image FAT32 test étendue à 161 secteurs : boot sector + zéros +
  bloc FDS=160 avec entry "HELLO   BIN" cluster=3, size=$DEADBEEF.
- Test ASSERT après boot kernel : `FS_OPEN_RESULT=0`,
  `FS_FOUND_CLUSTER=$00000003`, `FS_FOUND_SIZE=$DEADBEEF`.

#### Limitations v0.1
- 1 secteur de root dir max (16 entries). Cluster chain non parcourue.
- LBA root = `FS_FDS` (suppose `FS_ROOT=2`). Si `FS_ROOT > 2`, faut
  calculer `FDS + (FS_ROOT-2)*FS_SPC` — reporté v0.2.
- Pas de support LFN (long filename).

#### Reportés (OS-2.j.5+)
- **OS-2.j.5** : `kernel_fat_read(file, dest, size)` — traverse FAT
  chain via lookups dans la FAT.
- **OS-2.j.6** : intégration loader (charge app depuis SD).

---

## [0.23.0] - 2026-05-08

### Sprint 2.j.3 — Parse complet boot sector FAT32

#### Added
- **`fat_parse_boot_sector`** (helper interne appelé par fat_init après
  signature OK) : parse 6 champs critiques du boot sector FAT32 :
  - `FS_BPS` (2B) bytes per sector — offset $0B
  - `FS_SPC` (1B) sectors per cluster — offset $0D
  - `FS_RSC` (2B) reserved sectors count — offset $0E
  - `FS_NFAT` (1B) num FATs — offset $10
  - `FS_SPF` (4B) sectors per FAT (FAT32) — offset $24
  - `FS_ROOT` (4B) root cluster (FAT32) — offset $2C
- **Calcul `FS_FDS`** (first data sector) = `FS_RSC + FS_NFAT * FS_SPF`
  par boucle d'addition (NFAT typique = 2). v0.1 limite à 16-bit
  (disque < 32 MiB), high bytes = 0.
- **Constantes `BS_*`** pour les offsets dans le boot sector.

#### Validation
- 503 tests OK (compteur inchangé, ASSERT étendus dans le test
  fat_init existant).
- Test `test_oricos_fat_init_validates_fat32_signature` étendu : ASSERT
  les 6 champs parsés + FS_FDS calculé sur image FAT32 minimale
  (BPS=512, SPC=1, RSC=32, NFAT=2, SPF=64, ROOT=2 → FDS=160).

#### v0.1+ (reportés OS-2.j.4+)
- **OS-2.j.4** : `kernel_fat_open(filename)` — read root dir cluster,
  scan entries 32B pour 8.3 match, retourne first_cluster + size.
- **OS-2.j.5** : `kernel_fat_read` traverse FAT chain.
- **OS-2.j.6** : intégration `kernel_app_exec` charge depuis SD.

---

## [0.22.0] - 2026-05-08

### Sprint 2.j.2 — kernel_fat_init (signature FAT32)

#### Added
- **`kernel_fat_init`** : lit boot sector (LBA 0) via `kernel_sd_read_block`,
  vérifie signature `"FAT32"` à offset $52 du boot sector. Retourne via
  `FS_INIT_RESULT` ($016160) : $00 OK ou $01 BAD.
- **Constantes `FS_BUFFER` ($015F60), `FS_INIT_RESULT` ($016160),
  `FS_FAT32_SIG = $52`**.
- Buffer FS distinct du buffer test sd_read_block ($015D40) — préserve
  les ASSERT pattern A..Z du Sprint 2.j.1.
- Test au boot : `kernel_fat_init` après `kernel_sd_read_block`.

#### Validation
- 503 tests OK (502 → +1).
- Test `test_oricos_fat_init_validates_fat32_signature` : image FAT32
  minimale, ASSERT mem[$015F60+$52..+$56] = "FAT32" et
  mem[$016160] = $00.
- Test sd_read_block étendu : sur image pattern A..Z (pas de signature),
  ASSERT mem[$016160] = $01 (BAD).

#### v0.1+ (reportés OS-2.j.3+)
- **OS-2.j.3** : parser complet boot sector (bytes_per_sector,
  sectors_per_cluster, reserved_sectors, num_fats, sectors_per_fat,
  root_cluster) → calcul `first_data_sector`.
- **OS-2.j.4** : `kernel_fat_open(filename)` lecture root dir + lookup
  fichier 8.3.
- **OS-2.j.5** : `kernel_fat_read(file, dest, size)` traverse FAT chain.
- **OS-2.j.6** : intégration loader (charger app depuis SD au lieu de
  `.incbin`).

---

## [Unreleased] - 2026-05-08

### Sprint 2.j.1 — Test fonctionnel SD validé

- Test côté Phosphoric `test_oricos_sd` : pipeline complet driver
  kernel `kernel_sd_read_block` ↔ device SD émulé ↔ fichier image
  hôte. Image test 512B (pattern A..Z répété) chargée, kernel lit
  bloc 0 au boot, ASSERT contenu en bank 1 $5D40+.
- 502 tests OK.

---

## [0.21.0] - 2026-05-08

### Sprint 2.j.0 — Driver bloc SD minimal

#### Added
- **`kernel_sd_read_block`** : lecture d'un bloc 512 octets via le device
  SD émulé (mappé à `$0320-$0327` en bank 0).
- **Convention v0.1** : LBA 16-bit en zero page `$30`/`$31`, destination
  via `DP_PCPTR` (24-bit pointer en `$0C-$0E`). Bit 16-23 du LBA ignoré
  (max 32 MiB en v0.1, à étendre).
- **Constantes SD_LBA_LO/MID/HI/CTRL/DATA** + `SD_CTRL_READ`/`SD_CTRL_BUSY`.
- Test au boot : `kernel_sd_read_block(LBA=0, dest=$01:5D40)`. Sans
  image SD : copie 512 zéros (no-op fonctionnel). Avec image : lit
  bloc 0.

#### Validation
- 501 tests OK (pas de régression).
- Sans crash quand sd_read_block appelé sans image SD active.
- Test fonctionnel avec image réelle reporté OS-2.j.1.

#### v0.1+ (reportés)
- **OS-2.j.1** : test fonctionnel avec image SD réelle (FAT32 ou raw).
- **OS-2.j.2** : parser FAT32 boot sector + root dir lookup.
- **OS-2.j.3** : `kernel_fat_open(filename)` lecture fichier.
- **OS-2.j.4** : intégration loader (charger app depuis SD au lieu de
  `.incbin` dans kernel.bin).
- LBA 24-bit (8 GiB), écriture, asynchrone busy.

---

## [0.20.0] - 2026-05-08

### Sprint 2.m.1 — Première app asm "hello" standalone ✨

#### Added
- **`apps/hello/hello.s`** : source asm 65C816 mode N de la première
  app standalone d'OricOS. Code position-independent : `ldx #'Z' ;
  lda #$01 ; cop #$AA ; rtl`. Charge à `$BANK_APP:$0200`.
- **`apps/hello/hello.cfg`** : ld65 config flat binary, segment CODE
  loaded à `$0200`.
- **`apps/hello/Makefile`** : pipeline build app : `ca65` → `ld65` →
  `oricos-bundle.py` → `.oosobj`.
- **`tools/oricos-bundle.py`** : script Python qui wrappe un binaire
  flat dans un bundle OricOS Object v1 (header 8B + section CODE
  entry 8B + data). Usage : `oricos-bundle.py input.bin output.oosobj`.
- **`Makefile` racine** étendu : variable `APPS = hello`,
  build récursif des apps avant le kernel, dependency
  `$(KERNEL_O): ... $(APP_BUNDLES)` pour rebuild kernel quand un
  bundle change. `make clean` aussi récursif.
- **`kernel.s`** : `bundle_test` désormais via `.incbin
  "../apps/hello/build/hello.oosobj"` au lieu d'inline `.byte`. Le
  kernel embarque le bundle produit par le pipeline app externe.

#### Validation
- 501 tests OK (compteur inchangé — le test 'Z' à $BBAB passe avec
  la nouvelle source).
- Bundle généré : 23 bytes (8 header + 8 section entry + 7 code).
- Pipeline build complet : source asm app → binaire flat → bundle
  .oosobj → embedded dans kernel.bin → loaded par kernel_app_exec
  → exec en bank dédiée → syscall print.

#### Importance
- C'est le **premier exécutable userland OricOS** dont la source vit
  hors du kernel. Démontre la viabilité du pipeline d'apps tierces.
- Sprint 4 (userland C llvm-mos) reposera sur le même pipeline mais
  avec compilateur C → ld65 → oricos-bundle.

#### v0.2 (reportés)
- App avec sections multiples (CODE + DATA + ICON).
- App avec manifest (nom, version, auteur, args).
- 2e app de test (graphics demo, calculator).
- llvm-mos toolchain Sprint 4.

---

## [0.19.0] - 2026-05-08

### Sprint 2.l.1 — kernel_app_exec : LOADER COMPLET ✨

#### Added
- **`kernel_app_exec (DP_PTR)`** : orchestre l'exécution complète d'une
  app bundle. Pipeline :
  1. `kernel_bundle_validate` (magic + version).
  2. `kernel_bundle_find_code` (size + offset section CODE).
  3. `kernel_alloc_bank` → bank app dédiée.
  4. **Copy** section CODE de bundle vers `bank:0200` via DP indirect
     long (`[$18],Y` source, `[$1B],Y` dest, byte-by-byte).
  5. **Patch JSL self-modifying** : écrit `BUNDLE_APP_BANK` au byte 4
     de `app_exec_call` (instruction JSL al). Workaround ld65 :
     utilise `STA [dp]` long indirect car `STA al` sur label CODE
     génère bank=$00 par défaut.
  6. `jsr app_exec_call` → exécute JSL `$BANK:0200`.
- **`bundle_test`** refactor : section CODE = vraie app `ldx #'Z';
  lda #$01; cop #$AA; rtl` (7 bytes). Exécute en bank app via syscall
  SYS_PRINT_CHAR pour écrire 'Z' à l'écran.
- **`BUNDLE_APP_BANK`** ($01549F) : bank alloué pour app courante.

#### Validation
- Test d'intégration : ASSERT `mem[$00BBAB] = 'Z'` — l'app a écrit 'Z'
  via syscall depuis bank 7. ASSERT `mem[$01549F] = $07`.
- 501 tests OK.
- **Démo SDL2 visible** : "OricOS v0.7" + "YABZ" sur écran (Y kernel
  syscall + AB hex + **Z app loader**).
- Golden frame régénérée pour test visuel pixel-perfect.

#### Note technique
- ld65 ne distingue pas le bank d'un label dans un segment. `STA al`
  sur label = bank $00 par défaut. Workaround : init pointer 24-bit
  en DP zero page avec bank explicite ($01) puis `STA [dp]`.
- App tourne en mode N + M=1/X=1 préservés (cf. fix PH-bug-dp-indirect-Y
  bank1 sur P mode N qui rendait possible cop syscall propre).

#### v0.2 (reportés)
- Free bank app après exit (kernel_free_bank).
- Multi-section CODE+DATA+ICON+MANIFEST.
- App args via syscall (argc/argv).
- Sandbox bank-based — privilèges app (ADR-15 future).

---

## [0.18.0] - 2026-05-08

### Sprint 2.l.0 — kernel_bundle_find_code (parse sections)

#### Added
- **`kernel_bundle_find_code (DP_PTR)`** : parse les sections d'un
  bundle, trouve la section CODE. Retourne :
  - A = `BUNDLE_OK` ($00) si trouvée, `BUNDLE_ERR_NOT_FOUND` ($03) sinon.
  - `BUNDLE_FOUND_SIZE` ($015498, 16-bit) = taille section.
  - `BUNDLE_FOUND_OFFSET` ($01549A, 16-bit) = offset relatif au bundle.
- **Constantes** `BNL_HDR_SIZE=8`, `BNL_SEC_SIZE=8`, `BNL_SEC_TYPE/SZ_LO/
  SZ_HI/OFF_LO/OFF_HI`.
- **Test au boot** : `kernel_bundle_find_code` sur `bundle_test`.
  ASSERT côté Phosphoric : SIZE=$0002, OFFSET=$0010.

#### Notes implémentation
- `cpx` n'a pas de variant long-absolute (24-bit). Utilise tmp DP
  zero page `$15` pour stocker nsec et faire `cpx zp`.
- Boucle parcourt les sections jusqu'à TYPE=CODE ou nsec atteint.
- Calcul entry offset : `(X+1)*8` (= BNL_HDR_SIZE + X*BNL_SEC_SIZE
  pour valeurs 8/8). À généraliser quand HDR/SEC tailles changeront.

#### Validation
- 501 tests OK.

#### v0.1 (suite — OS-2.l.1)
- `kernel_app_exec (DP_PTR)` : validate + find_code + alloc_bank +
  copy code section vers `bank:0200` + JSL self-modifying.
- App test : bundle inline avec section CODE = `ldx #'Z'; lda #$01;
  cop #$AA; rtl`.

---

## [0.17.0] - 2026-05-08

### Sprint 2.k.1 finalisé — bug Phosphoric corrigé, validate fonctionnel

#### Fixed (côté Phosphoric, PH-bug-dp-indirect-Y-bank1)
- Bug majeur 65C816 mode N : COP/BRK/IRQ/NMI/PHP/PLP/RTI manipulaient
  P avec masque mode E qui en mode N corrompait les flags X/M (index
  width / accumulator width).
- Manifestation OricOS : `cop #$AA` syscall corrompait X (passait à
  16-bit) au RTI → `ldy #$00` du caller consommait 2 bytes d'imm →
  crash $00:0000.

#### Changed (OricOS)
- `kernel_bundle_validate` ré-activé au boot. Validate OK confirmé
  pour `bundle_test` inline. ASSERT côté Phosphoric : `mem[$01549C]=$00`.
- Tous les `[dp],Y` long indirects et opérations dépendantes de X/M
  fonctionnent désormais après COP/IRQ/NMI.

#### Tests
- 501 tests OK.
- Démo SDL2 toujours fonctionnelle.

---

## [0.16.0] - 2026-05-08

### Sprint 2.k.1 — Format bundle apps (ADR-08 v0.1 partiel)

#### Added
- **Spec format bundle "OOS\x01"** : header 8B (magic 4B + version 1B +
  flags 1B + num_sections 1B + reserved 1B) + section entries 8B
  (type, reserved, size 2B, offset 2B, reserved 2B) + section data.
  Types : CODE ($01), DATA ($02), ICON ($03), MANIFEST ($04).
- **Constantes** `BUNDLE_MAGIC_*`, `BUNDLE_VERSION`, `BUNDLE_SEC_*`,
  `BUNDLE_OK`/`BUNDLE_ERR_*`, offsets `BNL_*`.
- **`kernel_bundle_validate (DP_PTR)`** : code écrit (ldy/lda [dp],Y/
  cmp/bne/iny/rts). Vérifie magic + version, retourne A=$00 OK ou
  code erreur.
- **`bundle_test`** inline dans CODE segment : header + 1 section
  CODE 2 bytes (RTS RTS placeholder).

#### Known issue (OS-2.k.2 reportée)
- **Crash mystérieux** quand `kernel_bundle_validate` est appelé au
  boot du kernel : la routine n'arrive pas à terminer (CPU crash
  $00:0000). Hypothèse : bug subtil Phosphoric `lda [dp],Y` quand
  DP_PTR_BK = $01 et offset spécifique. Validate fonctionne à certaines
  positions, crash à d'autres. Print_string utilise le même opcode
  sans souci.
- **Tracé** dans BACKLOG : `PH-bug-dp-indirect-Y-bank1`. À investiguer
  via test unitaire isolé dans Phosphoric (test_cpu65c816_native.c).
- **Workaround temporaire** : `kernel_bundle_validate` non appelé
  au boot ; placeholder `lda #$00; sta BUNDLE_VALIDATE_RES`.

#### Validation
- 500 tests OK (compteur inchangé — le validate n'est pas testé
  fonctionnellement).
- Le code validate reste dans le kernel pour usage futur après fix bug.

#### v0.2 (reportés)
- Fix crash `[dp],Y` ou contournement via `[dp]` long indirect.
- `kernel_bundle_find_section (type)` : trouve section par type.
- `kernel_app_exec (DP_PTR)` : load + exec section CODE en bank dédiée.
- Test : un bundle test exec écrit char à l'écran via syscall.

---

## [0.15.0] - 2026-05-08

### Sprint 2.g.1 — Refactor scheduler vers TCB-based (ADR-14)

#### Added
- **ADR-14 ratifiée** : table fixe 16 TCBs en bank 1 $5C00 + bitmap free
  16 bits à $5B00. Layout TCB 20 octets (PID, STATE, PRIO, PARENT,
  saved_S, entry_pc, code_bank, data_bank, stack_bank, flags, name 8B).
- **Constantes TCB_*** : offsets champs, états (DEAD/READY/RUNNING/
  BLOCKED/ZOMBIE), alias TCB_1/TCB_2/TCB_1_S/TCB_2_S pour les 2
  premiers slots.
- **Init au boot** : bitmap `$07` (slot 0 invalide + TCB_1 + TCB_2).
  TCB_1 init RUNNING (task A), TCB_2 init READY (task B). Champs
  PID/STATE/PRIO/PARENT/PC/PB/DB tous initialisés. saved_S task B = $02F4.

#### Changed
- **`TASK_CUR`** sémantique : 0/1 → 1/2 (PID 1=task A, 2=task B).
- **Scheduler `do_switch`** refactor : sauve dans `TCB_1_S`/`TCB_2_S`
  au lieu de `TASK_A_S`/`TASK_B_S`. Met à jour les `STATE` des TCBs
  (READY ↔ RUNNING) à chaque swap.
- **Symboles `TASK_A_S`/`TASK_B_S`** retirés (remplacés par
  TCB_1_S/TCB_2_S).

#### Validation
- Test 2.a `test_oricos_sprint2a_via_t1_timer_drives_scheduler` : PASS.
- Test visuel `test_oricos_visual_matches_golden` : PASS pixel-identique
  au golden — preuve que le comportement est strictement préservé.
- 501 tests OK (compteur inchangé).

#### v0.2 (reportés)
- `kernel_task_create` dynamique (alloc PID via bitmap scan, init TCB
  depuis args, alloc stack page).
- `kernel_task_destroy` (set STATE=DEAD, clear bitmap bit).
- `kernel_task_yield` syscall.
- Scheduler avec priorité réelle (skip basse-prio si haute-prio READY).
- N tasks > 2 dans le test.

---

## [0.14.0] - 2026-05-08

### Sprint 2.i.1 — Modèle erreur kernel (panic + print_hex8)

#### Added
- **`kernel_panic` (A=code)** : stocke le code dans `PANIC_CODE`
  ($015495), affiche "PANIC <hex>" via `print_string`+`print_hex8`,
  puis STP. Remplace l'ancien `kernel_panic` stub (juste STP).
- **`kernel_print_hex8` (A=byte)** : écrit 2 chars hex (high/low nibble).
  Tail-call vers `kernel_print_nibble`.
- **`kernel_print_nibble` (A=0..15)** : écrit 1 char hex `0-9`/`A-F`,
  tail-call vers `kernel_print_char`.
- **`panic_msg`** : string "PANIC " ($00-terminée) en CODE segment.
- **Test au boot** : `lda #$AB; jsr kernel_print_hex8` après le syscall
  COP. Vérifie que `mem[$BBA9]='A'`, `mem[$BBAA]='B'`. Démo SDL2
  affiche "YAB" sur ligne 2.

#### Validation
- 498 tests OK.

#### v0.2 (reportés)
- **Log ring buffer** (256 bytes en bank 1) : `kernel_log_byte`,
  `kernel_log_str`. Lectur via syscall.
- **SYS_PANIC syscall** ($02) : userland peut déclencher panic via COP.
- **Stack trace** : trace les RTS jusqu'à kernel_entry au moment du panic.
- **Codes panic standardisés** : enum `PANIC_NULL_PTR`, `PANIC_STACK_OVF`,
  `PANIC_INVALID_SYSCALL`, `PANIC_BANK_EXHAUSTED`, etc.

---

## [0.13.0] - 2026-05-08

### Sprint 2.h.1 — Bank allocator avec free (LIFO list)

#### Added
- **Free list LIFO 16 entries** : `BANK_FREE_LIST` ($0154A0, 16 bytes)
  + `BANK_FREE_TOP` ($0154B0, count 0..16).
- **`kernel_alloc_bank` étendu** : pop free list si non vide, sinon
  bump (ancien comportement). Conserve la sémantique "0 = épuisé".
- **`kernel_free_bank`** (nouvelle routine) : push bank num sur free
  list, drop silencieux si pleine.

#### Validation
- Test au boot : alloc 3 ($04, $05, $06), free $05, alloc → doit
  retourner $05 (LIFO), pas $07 (bump). Stocké à `BANK_DEMO+3`.
- ASSERT côté test : `mem[$015463] = $05`.
- 498 tests OK.

#### v0.2 (reportés)
- Bitmap allocator (256 bits = 32 bytes) pour fragmentation arbitraire.
- Réservation explicite de banks (mark-as-used).
- Compteur de banks libres exposé via syscall (SYS_BANK_COUNT_FREE).

---

## [0.12.0] - 2026-05-08

### Cleanup — basculer vers opcodes natifs après fixes Phosphoric

#### Changed
- **`kernel_entry`** : `ldx #$FF; txs` (mode N + X=1, S=$00FF par bug
  perçu) → `lda #$01FF; tcs` (M=0). Stack désormais en page 1 standard
  $01FF — clarifié WDC §A.32 : SEP #$10 force X high=0, TXS copie X
  entier → S=$00:XL. Pour stack page 1, utiliser TCS.
- **`kernel_print_char`** : `STA [DP_PCPTR]` (long indirect $87 + bank
  explicite en DP+$0E) → `STA (DP_PCPTR)` (DP indirect $92, écrit à
  DBR:ptr). Code plus court, plus idiomatique. Possible suite à
  PH-fix-dp-indirect côté Phosphoric.

#### Fixed
- DP_PCPTR réduit de 24-bit à 16-bit (DP+$0C/$0D), bank fournie par DBR=0.

#### Tests
- 498 tests OK.

---

## [0.11.0] - 2026-05-08

### Sprint 2.f.1 — Mécanisme syscall COP (ADR-13 ratifiée)

#### Added
- **ADR-13 ratifiée** : OricOS expose ses services via `cop #$AA`
  (signature OricOS magic). Numéro de syscall en `A`, args en `X`/`Y`.
  Référence : GS/OS sur Apple IIgs.
- **Segment `COP_HANDLER`** dans `kernel.cfg` à `$5700` (bank 1).
- **`kernel_cop_handler`** (v0.1 minimal, dispatch hardcoded) :
  - `A=$01` (SYS_PRINT_CHAR) : `X` = char → call `kernel_print_char`.
  - Autres syscalls : ignored (rti immediat).
  - v0.2 : table de pointers indexée par A*2 (256 syscalls max).

#### Validation
- Test au boot kernel : `ldx #'Y'; lda #$01; cop #$AA` →
  test vérifie `mem[$BBA8] = 'Y'`.
- 494 tests OK.
- Démo SDL2 : "OricOS v0.7" sur ligne 1 + "Y" sur ligne 2 (résultat
  du syscall).

#### Note
- Phosphoric supporte déjà l'opcode COP en mode N (push PB+PC+P,
  clear PBR, vector $00FFE4). Trampoline bank 0 $0150 = JML $015700
  installé par main.c (`--kernel`) et par `test_oricos_boot.c`.

#### v0.2 (reportés)
- Table de dispatch (à la place du `cmp #$01`).
- Plus de syscalls (SYS_PRINT_STRING, SYS_KBD_GET, SYS_BANK_ALLOC).
- ABI versioning (utiliser le byte signature COP comme version).

---

## [0.10.0] - 2026-05-08

### Sprint 2.e.1 — Driver console générique (print_char / print_string)

#### Added
- **`kernel_console_init`** : `CURSOR_ADDR=$BB81`, `CURSOR_X=1` (col 1
  après attribute byte INK $07).
- **`kernel_print_char (A=char)`** : gère char normal et LF (`$0A`).
  Stocke le char à `bank0:CURSOR_ADDR` via `STA [DP_PCPTR]` (opcode
  `$87` long indirect, pointer 24-bit en DP+$0C/$0D/$0E avec bank=$00).
  Avance `CURSOR_ADDR` et `CURSOR_X`. Wrap fin de ligne (CURSOR_X=40
  → reset à 0). Clamp si `CURSOR_ADDR >= $BFE0` (scroll v0.2).
- **`kernel_print_string (DP_PTR = ptr 24-bit)`** : lit string null-
  terminée via `LDA [DP_PTR],Y` (opcode `$B7`), boucle `print_char`.
- **`kernel_print_banner`** réécrit via `print_string` (banner_str =
  "OricOS v0.7\n\0" en CODE segment).
- **2 pointers DP séparés** : `DP_PTR` ($08-$0A) pour print_string
  (bank 1 strings) et `DP_PCPTR` ($0C-$0E) pour print_char (bank 0
  screen RAM). Évite la collision lors de print_string → print_char.

#### Diagnostic important — bug Phosphoric découvert
- **Opcode `$92` (STA (dp), DP indirect 16-bit) NON IMPLÉMENTÉ dans
  Phosphoric** + 7 autres opcodes DP indirect 65C816 manquants ($12,
  $32, $52, $72, $B2, $D2, $F2). Le decoder traite `$92` comme NOP
  size=1 (table opcode 6502), donc l'opérande est ré-interprété comme
  opcode → corruption stack → crash.
- Contournement OS-2.e.1 : utiliser `STA [dp]` (long indirect, $87,
  implémenté) avec bank explicite en DP+$0E.
- Tracé en dette technique workspace (`PH-fix-dp-indirect`).

#### Validation
- 494 tests OK (compteur inchangé).
- Démo SDL2 (`oric1-emu --kernel build/kernel.bin`) affiche
  "OricOS v0.7" en blanc à $BB81+ (banner via print_string).
- Screenshot test_oricos_sprint2a vérifie attribute byte $07 +
  banner "OricOS v0.7" + clear screen comme avant.

#### v0.2 (reportés)
- Carriage return (`$0D`).
- Scroll up.
- Attribut couleur multiple par ligne.
- Cursor blink visuel.

---

## [0.9.0] - 2026-05-08

### Sprint 2.d.1 — Driver clavier matrice (scan via PSG R14)

#### Added
- **Routines PSG bus** (`psg_set_reg`, `psg_write_data`, `psg_read_data`)
  via VIA PCR (CA2=BC1, CB2=BDIR). Constantes : `PCR_LATCH_ADDR=$EE`,
  `PCR_WRITE_DATA=$EA`, `PCR_READ_DATA=$AE`, `PCR_INACTIVE=$AA`.
- **`kernel_kbd_init`** : `DDRA=$FF`, `DDRB=$F7`, PSG R7=`$FF` (port A
  input), init `KBD_MATRIX[0..7]=$FF` (= no key pressed, active low).
- **`kernel_kbd_scan`** : scan 8 colonnes via VIA ORB[0:2] + lecture
  PSG R14, stocke matrice 8 octets à `$015470`. Appelé depuis IRQ T1
  handler à chaque tick.

#### Changed
- **Période T1 : 512 → 4096 cycles** (`T1_PERIOD_HI = $10`). Le scan
  dure ~830 cycles ; à 512 cycles de période, T1 ré-asserte avant que
  les tasks aient le temps d'exécuter (B_ctr restait à 0). 4096 cycles
  = 8 ticks/frame PAL, ~3000 cycles/slot disponibles aux tasks.

#### Validation
- 494 tests passent (compteur inchangé).
- `test_oricos_sprint2a` : avec scan actif, A_ctr=149 B_ctr=66 swap=9
  (vs A=247 B=239 sans scan, avant T1=512 → 4096).

#### Known issue (à creuser)
- **Bug Phosphoric latent** : `TXS` en mode N M=X=1 + ldx 8-bit copie
  seulement low byte → S high = $00 (au lieu de $01 attendu pour page 1
  stack). Stack OricOS tourne en bank 0 page 0 par chance. Observable
  via `TASK_A_S=$00F8` après save_A. Tracé dans `BACKLOG.md` racine
  workspace. Ne casse rien actuellement — à fixer côté Phosphoric.

---

## [Unreleased] - 2026-05-08

### Docs — Roadmap révisée suite point critique architecte
- §7 CLAUDE.md : insertion Sprints 2.d → 2.m comme prérequis stricts
  avant Sprint 3 GUI (driver clavier, console générique, syscalls,
  TCB refactor, allocator avec free, modèle d'erreur, FAT32, bundle
  apps, app loader).
- Source de vérité : `../BACKLOG.md` racine workspace.

---

## [0.8.0] - 2026-05-08

### Sprint 2.c+ — Fonte char embarquée (autonomie OS native)

#### Added
- **`data/charset.bin`** : fonte char 1024 octets (128 chars × 8 lignes),
  extraite de `roms/basic11b.rom` offset `$3B78`. Embarquée dans
  `kernel.bin` via `.incbin` au sein du segment `CHARSET`.
- **`kernel_install_charset`** : routine de boot qui copie 1024 octets
  de `bank 1 $5800` (segment CHARSET) vers `bank 0 $B400` (zone fonte
  Oric 1 mode TEXT). Boucle long-addressing, X 16-bit.
- **Segment `CHARSET`** dans `kernel.cfg`, start `$5800` (après
  IRQ_HANDLER à `$5600`).
- **Attribute byte `$07` (INK 7 = blanc)** écrit en `$00BB80`
  par `kernel_print_banner` pour rendre le banner visible (sans
  cela, INK par défaut = 0 = noir invisible).

#### Why
Le rendu Oric 1 mode TEXT lit la fonte char depuis RAM bank 0
`$B400-$B7FF`. La ROM Oric 1 historique copie cette fonte au boot
depuis sa propre image. OricOS boote sans la ROM Oric 1 — donc la
zone reste à zéro et tous les chars rendent en pixels noirs.
Solution philosophiquement cohérente avec l'identité d'OS natif :
embarquer la fonte directement dans `kernel.bin` et l'installer au
boot. OricOS devient totalement indépendant de la ROM Oric 1.

#### Validation
- `make` produit `build/kernel.bin` (57 344 octets, fill complet bank 1).
- Char 'O' confirmé à file offset `0x5878` (bitmap `1c 22 22 22 22 22 1c 00`).
- Test `test_oricos_sprint2a_via_t1_timer_drives_scheduler` passe (494 tests).
- Démo visible (`oric1-emu --kernel build/kernel.bin`) : "OricOS v0.7"
  s'affiche en blanc en haut-gauche dans la fenêtre SDL2.

---

## [0.7.0] - 2026-05-08

### Sprint 2.c — Driver console minimal
- `kernel_clear_screen` : remplit screen RAM Oric 1 (40x28, 1120 octets)
  d'espaces ASCII via boucle X 16-bit + STA long abs,X.
- `kernel_print_banner` : écrit "OricOS v0.7" à `$00BB80+1`.

## [0.6.0] - 2026-05-08

### Sprint 2.b — Bank allocator
- `kernel_alloc_bank` : allocation incrémentale pool banks 4-127.
- 3 démo allocs au boot, stockés à `BANK_DEMO+0..2`.

## [0.5.0] - 2026-05-08

### Sprint 2.a — VIA T1 drives scheduler
- Setup VIA T1 mode continuous IRQ (ACR=$40, T1CL/T1CH=$0200, IER=$C0).
- Scheduler ack via lecture `T1CL`.
- 10 ticks → STP propre.

## [0.4.0] - 2026-05-08

### Sprint 1.c — IRQ-driven scheduler

## [0.3.0] - 2026-05-08

### Sprint 1.b — Preemptive scheduler 2 tasks (round-robin)

## [0.2.0] - 2026-05-08

### Sprint 1.a — Native interrupts + sentinel "ORIOS\x00"

## [0.1.0] - 2026-05-08

### Sprint 0 — Hello world boot
- Bascule mode N (XCE), sentinels en bank 1.
