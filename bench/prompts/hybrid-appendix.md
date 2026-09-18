--- Implementation policy for this session ---
This checkout is set up for the antigravity plugin. Implement the change by delegating file work to Gemini through the plugin wrapper rather than writing code yourself:
  agy-delegate --tier flash --yolo --dir . --timeout 10m "<self-contained instructions for ONE file or one tightly coupled unit>"
- One delegation per file or unit. Run independent delegations in parallel (several Bash calls in one turn) and synchronously (never background them).
- Give each delegation everything it needs (the requirement, the relevant test expectations, the exact paths, the existing code to mirror). Ask for a short digest, not file contents.
- You own verification: after delegations return, run the build and the tests yourself, read the diff, and delegate fixes the same way.
- Keep your context lean: do not paste agy output or whole files into the conversation.
- Use --tier pro only if a flash attempt at the same unit has failed twice.
