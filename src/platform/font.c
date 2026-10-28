/* Native font discovery only; glyph rasterization stays in Velocitty. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FONT_LIMIT (64u * 1024u * 1024u)

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

unsigned char *
velocitty_font_load(const char *family, int bold, int italic, int exact, size_t *len)
{
    WCHAR name[LF_FACESIZE], actual[LF_FACESIZE];
    HDC dc;
    HFONT font;
    HGDIOBJ old;
    DWORD n;
    unsigned char *data = NULL;
    if (!family || !len) return NULL;
    if (!exact && strcmp(family, "monospace") == 0) family = "Consolas";
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, family, -1, name, LF_FACESIZE)) return NULL;
    dc = CreateCompatibleDC(NULL);
    if (!dc) return NULL;
    font = CreateFontW(16, 0, 0, 0, bold ? FW_BOLD : FW_NORMAL, italic, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_TT_ONLY_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
        FIXED_PITCH | FF_MODERN, name);
    if (!font) { DeleteDC(dc); return NULL; }
    old = SelectObject(dc, font);
    if (exact && (!GetTextFaceW(dc, LF_FACESIZE, actual) || lstrcmpiW(name, actual) != 0)) goto done;
    n = GetFontData(dc, 0, 0, NULL, 0);
    if (n == GDI_ERROR || !n || n > FONT_LIMIT) goto done;
    data = malloc(n);
    if (data && GetFontData(dc, 0, 0, data, n) != n) { free(data); data = NULL; }
    if (data) *len = n;
done:
    SelectObject(dc, old);
    DeleteObject(font);
    DeleteDC(dc);
    return data;
}
#elif defined(__APPLE__)
#include <CoreText/CoreText.h>

static void put16(unsigned char *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static void put32(unsigned char *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

unsigned char *
velocitty_font_load(const char *family, int bold, int italic, int exact, size_t *len)
{
    CFStringRef name, actual;
    CTFontRef font, styled;
    CFArrayRef tags;
    CFDataRef tables[256] = {0};
    uint32_t table_tags[256];
    size_t n = 0, total, offset, count = 0;
    unsigned char *data = NULL;
    int cff = 0;
    if (!family || !len) return NULL;
    if (!exact && strcmp(family, "monospace") == 0) family = "Menlo";
    name = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    if (!name) return NULL;
    font = CTFontCreateWithName(name, 16, NULL);
    if (!font) { CFRelease(name); return NULL; }
    actual = CTFontCopyFamilyName(font);
    if (exact && (!actual || CFStringCompare(name, actual, kCFCompareCaseInsensitive) != kCFCompareEqualTo)) {
        if (actual) CFRelease(actual);
        CFRelease(name); CFRelease(font); return NULL;
    }
    if (actual) CFRelease(actual);
    CFRelease(name);
    CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    styled = traits ? CTFontCreateCopyWithSymbolicTraits(font, 16, NULL, traits, kCTFontBoldTrait | kCTFontItalicTrait) : NULL;
    if (styled) { CFRelease(font); font = styled; }
    tags = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
    if (!tags) { CFRelease(font); return NULL; }
    n = (size_t)CFArrayGetCount(tags);
    if (n > 256) goto done;
    total = 12 + 16 * n;
    for (size_t i = 0; i < n; i++) {
        uint32_t tag = (uint32_t)(uintptr_t)CFArrayGetValueAtIndex(tags, (CFIndex)i);
        CFDataRef table = CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions);
        if (!table) continue;
        size_t bytes = (size_t)CFDataGetLength(table);
        if (bytes > FONT_LIMIT || total > FONT_LIMIT - ((bytes + 3) & ~(size_t)3)) { CFRelease(table); goto done; }
        total += (bytes + 3) & ~(size_t)3;
        tables[count] = table; table_tags[count++] = tag;
        if (tag == 0x43464620) cff = 1; /* CFF */
    }
    if (!count) goto done;
    data = calloc(1, total);
    if (!data) goto done;
    put32(data, cff ? 0x4f54544f : 0x00010000);
    put16(data + 4, (uint16_t)count);
    uint16_t power = 1, selector = 0;
    while ((size_t)power * 2 <= count) { power *= 2; selector++; }
    put16(data + 6, power * 16); put16(data + 8, selector);
    put16(data + 10, (uint16_t)(count * 16 - power * 16));
    offset = 12 + 16 * count;
    for (size_t i = 0; i < count; i++) {
        size_t bytes = (size_t)CFDataGetLength(tables[i]);
        unsigned char *entry = data + 12 + 16 * i;
        put32(entry, table_tags[i]); put32(entry + 8, (uint32_t)offset); put32(entry + 12, (uint32_t)bytes);
        memcpy(data + offset, CFDataGetBytePtr(tables[i]), bytes);
        offset += (bytes + 3) & ~(size_t)3;
    }
    *len = offset;
done:
    for (size_t i = 0; i < count; i++) CFRelease(tables[i]);
    CFRelease(tags); CFRelease(font);
    return data;
}
#else
unsigned char *
velocitty_font_load(const char *family, int bold, int italic, int exact, size_t *len)
{
    (void)family; (void)bold; (void)italic; (void)exact; (void)len;
    return NULL;
}
#endif

void velocitty_font_free(void *data) { free(data); }
