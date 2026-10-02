Drawbridge v3.5 tightens automatic hyperlinking and repairs navigation-only saves while retaining the v3.4 interface without markup tools.

- Link destinations come only from OCR of the captured sheet-number region. Page ordinals, existing page labels, and bookmarks cannot supply destinations.
- References must match the full OCR-read sheet identifier. Bare numbers and approximate matches are excluded; ambiguous duplicate sheet numbers are skipped.
- Replacing generated links removes previously saved generated links instead of accumulating duplicates.
- Navigation saves preserve existing PDF content streams, resources, page geometry, and rotation. Fixes address PDF object allocation and validation failures.

Validation: six focused regression tests passed locally. The OCR-only workflow was exercised in the app on a 56-page LargeSet test copy: 55 sheet numbers detected, 204 links saved, old generated links replaced, and all 56 pages' content, resources, and geometry unchanged. The output grew by 54,245 bytes. OCR-unreadable sheet numbers are deliberately skipped.
