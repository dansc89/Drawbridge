Drawbridge v3.6 fixes missing automatic hyperlinks in PDFs that mix internal page rotations.

- Captured OCR regions now follow the visible page orientation, so the same title-block selection works across pages stored with different rotation metadata.
- Destinations still require an unambiguous sheet number read by OCR. Bare page numbers and approximate matches remain excluded.
- Retains the v3.5 interface without markup tools.

Validation: seven focused regression tests passed locally; one unrelated fixture test was skipped. Tests cover all four rotations, non-zero crop origins, and all 30 pages of the Mechanical mechanical fixture. In the application, the saved sheet index linked to all 29 other sheets, restoring the four previously missed destinations. All 30 pages retained their drawing streams, resources, page boxes, and rotations. The test output grew by 2,276 bytes.
