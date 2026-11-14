# Mumble server

A [Mumble](https://www.mumble.info) voice server for the [comm channel](../../docs/features/comm.md), run with Docker.  Mumble is open source, uses the Opus codec, and has push-to-talk built in.  People can join from the Mumble app on a computer or from Mumla on Android.

## Running it

On the machine that will host it, with Docker and Docker Compose installed:

```
cp .env.example .env
chmod 600 .env
# fill in both passwords, e.g. with: openssl rand -base64 18
mkdir data
docker compose up -d
docker logs mumble-server
```

The server listens on port 64738, TCP and UDP.  Its database, its certificate and the config it writes from the settings in `docker-compose.yml` are kept in `data/`.  It starts again after a reboot.  `docker compose down` stops it.

To join, give the app the host's address, port 64738, any username and the server password.  The server makes its own certificate, so each app warns about it the first time.  Accept it.

## From outside the house

Forward TCP and UDP port 64738 on the router to the host, and give people the router's public address or a dynamic DNS name.  Use a long server password before you do.

## Settings

- `MUMBLE_CONFIG_USERS`: how many people can be on at once.
- `MUMBLE_CONFIG_OPUSTHRESHOLD`: `0` makes everyone use Opus.
- `MUMBLE_CONFIG_REGISTERNAME`: the server's name, shown on its top channel.

Any other server setting can be given as `MUMBLE_CONFIG_` and its name.  To make channels or change permissions, log in from a Mumble app as `SuperUser` with the admin password.
