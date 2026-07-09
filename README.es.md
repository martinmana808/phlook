<p align="right"><a href="README.md">English</a> · <a href="README.es.md">Español</a></p>

# PHLOOK

**La experiencia de Fotos que ya conocés — pero tus archivos quedan como archivos comunes, en carpetas reales del disco. Sin bloque propietario de biblioteca.**

PHLOOK es un visor de fotos y videos nativo para macOS. Lee y muestra el contenido que vive en `~/Pictures/PHLOOK` como archivos normales — siempre tuyos, siempre movibles, legibles por cualquier otra herramienta, respaldables con una simple copia. PHLOOK sólo los indexa y los muestra; nunca encierra tus fotos dentro de una base de datos.

## El problema que resuelve

Fotos de Apple guarda tu biblioteca dentro de un enorme paquete propietario `.photoslibrary`. Tus fotos dejan de ser realmente *archivos* — quedan sepultadas en un bloque que sólo podés usar del todo a través de Fotos. PHLOOK te saca de esa cárcel: la misma experiencia familiar de grilla y visor, pero cada foto y video es un archivo común que te pertenece por completo.

## Qué hace

- **Explorar** — una grilla densa y rápida con tres densidades de zoom y un visor a pantalla completa (zoom con pellizco / control deslizante / ⌘-scroll, arrastrar para desplazar, navegación con flechas y gesto, animación de apertura/cierre estilo Fotos).
- **Navegar en el tiempo** — una barra de desplazamiento en el borde derecho con etiquetas de año, y vistas **Años / Meses / Todo** con fotos de portada que rotan solas.
- **Organizar** — una barra lateral con Biblioteca (Todo · Fotos · Videos · Live Photos), **Capturas** y **Selfies** detectadas automáticamente, **categorías con Vision** en el dispositivo (Naturaleza, Comida, Animales…), un filtro por **rango de fechas**, y **Ocultas** (protegido con Touch ID / la contraseña de tu Mac).
- **Live Photos** — emparejadas automáticamente, reproducidas a pedido, con un **selector de fotograma de portada** no destructivo (elegís cualquier fotograma del video; tus originales nunca se reescriben).
- **Limpiar** — **buscador de duplicados** (archivos idénticos byte a byte *y* pares original/editado de iOS `IMG` ↔ `IMG_E`) con un flujo seguro de revisar y mandar a la Papelera.
- **Traer contenido** — importar directo desde un iPhone (explorás el rollo de cámara, elegís lo nuevo), o soltás archivos en una carpeta de preparación y corrés un comando.
- **Interoperar** — Vista Rápida (barra espaciadora), arrastrar fotos a Finder / Final Cut / Mail, "Mostrar en Finder", copiar.

## Cómo se usa

### 1. Instalar
Compilá la app y copiala a `/Applications`:
```bash
make app
cp -R Phlook.app /Applications/
```
Después abrí **Phlook** desde Launchpad o Spotlight. En el primer inicio indexa tu biblioteca (los siguientes son casi instantáneos).

### 2. Traer tu contenido a la biblioteca
Tus fotos viven en `~/Pictures/PHLOOK`, nombradas `AAAA-MM-DD_HH-MM-SS_NombreOriginal.ext`. Tres maneras de agregar más:

- **Desde un iPhone (en la app):** conectás el teléfono → hacés clic en **Importar N nuevas** (o **Explorar…** para elegir ítems uno por uno). PHLOOK recuerda lo que ya importó, así que nunca te vuelve a ofrecer la misma foto.
- **Desde una carpeta de preparación:** soltás archivos (Captura de Imágenes, AirDrop, descargas) en `~/Pictures/PHLOOK_staging`, y después corrés:
  ```bash
  make ingest
  ```
  Renombra cada archivo según sus metadatos de captura, se niega a sobrescribir, saltea duplicados, y da un veredicto **LIMPIO / NO LIMPIO** — LIMPIO significa que es seguro borrar los originales del teléfono.
- **Manualmente:** copiás archivos directo a `~/Pictures/PHLOOK`. Se indexan en el siguiente inicio.

> **Excluir una carpeta:** cualquier subcarpeta cuyo nombre empiece con `_` queda dentro de la carpeta de la biblioteca pero **no se indexa** — ideal para soltar un archivo histórico que no querés mezclar en la grilla.

### 3. Uso diario
- **Doble clic** en una foto para abrir el visor; **barra espaciadora** para Vista Rápida; **arrastrá** una foto a otra app.
- **Clic** para seleccionar, **⌘-clic** para agregar, **⌘A** para todo, **clic derecho → Mover a la Papelera** (recuperable desde la Papelera de Finder).
- **⌘H** para Ocultar la selección; abrí **Ocultas** en la barra lateral y autenticate para verlas.
- **Buscar Duplicados** (barra de herramientas) para revisar y limpiar copias redundantes.

## Respaldos

Dos cosas independientes, dos respaldos:

- **La biblioteca (tus fotos + `phlook.db`)** → replicá a un disco externo:
  ```bash
  rsync -a --delete --exclude='.phlook' ~/Pictures/PHLOOK/  /Volumes/TuDisco/PHLOOK/
  ```
  Corrélo cuando quieras — copia sólo lo que cambió. Se saltea el caché de miniaturas `.phlook` (se regenera solo). La base de datos vale la pena guardarla: contiene las marcas de Ocultas, las portadas elegidas y el historial de importación, que no se pueden reconstruir sólo desde los archivos.
- **La app en sí** → `git push` (el código vive en este repositorio).

## Por dentro

macOS nativo, SwiftUI + AppKit, Swift Package Manager (no requiere Xcode — compila con Command Line Tools). Índice SQLite vía GRDB. El contenido queda intacto en el disco; PHLOOK sólo lee tus originales y escribe su propio índice pequeño.

## Filosofía

Tus fotos son tuyas. Deberían ser archivos comunes, en carpetas reales, legibles para siempre por cualquier herramienta — no rehenes de la base de datos de una sola app. PHLOOK te da la prolijidad de Fotos sin la cárcel.
