# Portable attachment acceptance fixture

Copied byte-for-byte from the coordinator's independent daily-writing acceptance
fixture on 2026-11-09. The source keeps its original CRLF endings, Chinese/space
angle path, existing attachment, missing/disguised/remote references, shared
reference definition/ordinary link and code examples. The disguised PNG is
intentional nonimage test data. Never normalize or simplify the Markdown fixture
to make collection pass.

`PortableAttachmentRegressionTests` copies this directory into a temporary root,
collects the document, moves only `notes`, removes `shared`, and resolves/decodes
the collected and pre-existing image bytes. `MD2_ATTACHMENT_ACCEPTANCE_FIXTURE`
can point the same test directly at the original external acceptance fixture;
the test only reads it and mutates its private temporary copy.
