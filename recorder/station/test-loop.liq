# McTrot radio, step 7: a 30-second test tone on loop, so the station is
# real (radio.mctrot.nyc/live.mp3, in any radio app) before the show
# exists. Step 8 replaces this with the scheduled long file and cue sheet.
#
# host/radio.nix fills in @tone@ (the tone, made at build time) and runs
# this as mctrot-radio. The Icecast source password arrives as a systemd
# credential, never in the Nix store.

settings.log.stdout := true
settings.log.file := false
settings.init.allow_root := false

credentials = environment.get("CREDENTIALS_DIRECTORY")
password = string.trim(file.contents("#{credentials}/icecast-source"))

# single() plays its file again each time it ends: the loop.
tone = single("annotate:artist=\"McTrot\",title=\"Test tone\":@tone@")

# mksafe: silence rather than nothing if the file ever can't be read, so
# listeners stay connected.
radio = mksafe(tone)

output.icecast(
  %mp3(bitrate = 128, samplerate = 44100, stereo = true),
  host = "127.0.0.1",
  port = @port@,
  password = password,
  mount = "live.mp3",
  name = "McTrot radio",
  description = "The soundtrack to a walk to every McDonald's in Manhattan",
  url = "https://mctrot.nyc/live",
  genre = "Various",
  public = false,
  radio
)
