# Verification driver

A standalone Node driver that exercises the DEPLOYED rails over public HTTPS
with throwaway real-network identities. See the repo README "Consumers" and
the deployment notes for how it was used. It depends on `@synonymdev/pubky`
(resolve it against any checkout that has it installed, e.g. pubky-app).

Subcommands: identities, connect, setup-start, setup-claim, setup-poll,
reader-marker, publish, negative, proof, status, lifecycle, credential.
