# Security

Juice is experimental and deliberately carries private entitlements including
`platform-application`, no-sandbox access, and task-port capabilities for child
launch helpers. It also exposes the host filesystem through Wine's `Z:` drive.
Any Windows executable launched by Juice should be treated like native code
with Juice's effective access, not like a safely isolated document.

Only run applications from sources you trust. Do not open arbitrary downloaded
EXEs or ZIPs. Keep sensitive data off test devices, review release entitlements,
and never distribute device-specific trust carriers or signing material.

The ZIP importer defends against traversal, unsupported encryption, malformed
directory records, CRC mismatch, and decompression-size abuse, but this does
not make the Windows program itself safe.

