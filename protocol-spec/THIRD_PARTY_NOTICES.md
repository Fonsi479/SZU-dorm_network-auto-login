# Third-party protocol fact notices

No third-party implementation source is copied into this project.

The SRun Base64 alphabet and two black-box cross-check vectors were compared
against `vidar-team/srun-login`, commit
`5a453c5343c0cade8633b0c89607c2d2daa478b8`, file
`internal/crypotoutil/base64.go` and its tests, licensed MIT. They are used only
as protocol facts to independently verify this clean-room implementation. The
project's complete BX1 vector uses separately chosen synthetic inputs.
