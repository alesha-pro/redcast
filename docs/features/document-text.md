# Document text

Agents read PDFs, scans, images and rich text through one shared reader: `read_file` for a file in
reach, and `web_fetch` and `read_page` for a PDF or an image on the web
([web search](web-search.md#reading-a-page)). It is this fork's, in `Features/DocumentText/`, and
builds on the clipboard's own extractor, which keeps working exactly as before.

## Invariants

- **A document is read in a child process that is gone when it answers.** `DocumentTextService`
  starts the bundled `ClipboardTextHelper` once per read with `document <kind> <path> <first page>
  <last page, 0 for open> <budget>` (`DocumentTextRequest`), so PDFKit, Vision and AppKit's importers
  never load into the app and their memory leaves with the process. The answer is `DocumentText` as
  JSON on a pipe read to at most twice the budget plus 64 KB; past that, or after 60 s, the helper is
  terminated and the read fails, saying which. Stop terminates it at once. It is reaped through
  `ProcessExit`, never `waitUntilExit`, whose run loop can miss the exit on a GCD thread. Nothing is
  cached and nothing stays running.
- **The clipboard's reads are unchanged.** `ClipboardTextExtractor` stays in `Clipboard/Service`
  with its own limits (32 KB, 64 pages) and commands (`image`, `pdf`, `thumbnail`); the fork opens
  only `recognize` and `render` to `DocumentTextExtractor`, and the helper's `main` sends the
  `document` command to it first. Those are the only upstream lines, each marked `Fork:`.
- **A file's kind comes from its extension, then its first bytes.** `DocumentKind.of`: `%PDF-` is a
  PDF, a PNG or JPEG signature an image, a NUL in the first 8 KB binary.

  | Kind | Read by | Largest file |
  | --- | --- | --- |
  | PDF | PDFKit page by page; a page with no text layer rendered and recognized by Vision OCR | 256 MB (mapped, not loaded) |
  | Image (png, jpeg, heic, tiff, gif, bmp, webp) | Vision OCR in strips, as the clipboard does | 32 MB |
  | Rich text (docx, doc, rtf, rtfd, odt) | `NSAttributedString` with `.officeOpenXML`, `.docFormat`, `.rtf`, `.rtfd`, `.openDocument` | 64 MB |
  | HTML | in the app, through [`WebPageMarkdown`](web-search.md#reading-a-page) (AppKit's HTML import needs the main thread and WebKit); `raw` reads the source | 10 MB |
  | Text | in the app, as UTF-8 | 10 MB |
  | Binary | refused by name | — |

- **A PDF is read by pages within a budget.** Whole pages, in order, until the next would pass the
  budget (24 KB for an agent); only a first page too long alone is cut, and says so. At most 50 pages
  a read (`DocumentPageRange.maxPages`), and no page is started after 40 s, since OCR takes about a
  second a scanned page. The answer heads each page with its number, marks one recognized by OCR as
  scanned, and ends with the pages that follow and how to ask for them (`pages "13-"`). A start past
  the end says how many pages there are.
- **Everything else pages by line.** Rich text and an image's OCR come back whole, up to 1 MB of
  text, and `read_file` numbers their lines and pages them with `offset` and `limit` like a text
  file, inside the 28 KB a result may carry, saying where to continue.

## Layout

| File | Holds |
| --- | --- |
| `Model/DocumentKind.swift` | A file's kind by extension and first bytes, each kind's size limit, which need the helper |
| `Model/DocumentPageRange.swift` | `"3"`, `"3-5"`, `"8-"`, clamped to a document and to 50 pages |
| `Model/DocumentText.swift` | What the helper read, page by page, and the answer a PDF or an image gives the model |
| `Model/DocumentTextRequest.swift` | One read as the command line both sides agree on |
| `Service/DocumentTextService.swift` | One helper per read: launch, bounded pipe, timeout, Stop, reaping |
| `Helper/DocumentTextExtractor.swift` | In the helper only: PDF pages with OCR, images, rich text, as JSON |

`project.yml` builds `Model/` and `Helper/` into `ClipboardTextHelper` and keeps `Helper/` out of the
app, so the app links neither PDFKit nor Vision for it.

## Manual sweep

- Give an agent (Files on) a folder with a text PDF, a scanned PDF, a DOCX, an RTF and a PNG
  screenshot, and ask what each says: every one reads, the scan's rows say "scanned", the PDF's
  answer names the pages that follow. Ask for a 300-page PDF's pages 120–125: one row, those pages.
- While a long scan is read, press Stop: `ps` shows no `ClipboardTextHelper` left.
- Copy a scanned PDF and a screenshot: Clipboard History's text search finds their words as before.

Harness: `document-text-test` (kinds by name and bytes, page ranges, the command line both ways,
cleaning and cutting on whole scalars, the answers; the extractor on a drawn PDF with a scanned
page, budgets and ranges, Word, RTF, ODT and DOC files, an image; and the service with the harness
as its own helper: a read, a missing helper, a failed read, a timeout, an answer past its bound and
Stop). `agent-tools-test` reads each kind through `read_file`, and `web-search-test` reads PDFs by
URL through the same helper.
