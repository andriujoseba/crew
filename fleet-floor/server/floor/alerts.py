"""Out-of-band notice when a roster box goes dark, and when it comes back.

Empty by design and named by #508's D1: the floor already SEES a dead box —
the ping tier counts its misses and `Fleet.get` renders it UNREACHABLE — and
tells nobody who is not looking at the page. #481 adds the telling, and this
is the seam it lands in, drawn here so that change is an edit to one module
rather than another section appended to the file this split took apart.

Nothing imports this module yet. It carries no code because the split is a
relocation and not a rewrite (D5): inventing an alert here to justify the
file would be exactly the behaviour change this issue forbids.
"""
