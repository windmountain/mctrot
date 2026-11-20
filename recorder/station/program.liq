# McTrot radio: the show, on the clock.
#
# The show is one long file and a program saying when it starts and
# what's on when (station/program.json's format; tools/radio_program.py
# makes both). They're uploaded to @station@ by hand, not deployed:
#
#   scp show-<hash>.flac program.json root@recorder.mctrot.nyc:@station@/
#
# A new program.json restarts this (host/radio.nix watches it).
#
# It airs every day at the program's time of day, not only on its date,
# and restarts itself after each day's show to line up the next.
#
# Every listener hears the same moment: started mid-show (a restart, a
# deploy, a new program), the show picks up at now − startsAt, by cueing
# the file in. Before the show, and after it, a holding loop plays (ten
# seconds of synthesized lounge music, station/holding.py, on repeat) with
# the program's "before" and "after" titles ("On air at 5:00 AM", "Off
# air"). Without a program, or without its file, it holds too.
#
# Artist and title follow the program, by the clock, and go to Icecast
# with the stream (radio apps show them). The API reads the same
# program.json for /live's now playing. Each change is logged ("on air:
# ..."), which is the on-air log: journalctl -u mctrot-radio.
#
# host/radio.nix fills in @station@, @holding@ and @port@ and runs this
# as mctrot-radio. The Icecast source password arrives as a systemd
# credential, never in the Nix store.

settings.log.stdout := true
settings.log.file := false
settings.init.allow_root := false

credentials = environment.get("CREDENTIALS_DIRECTORY")
password = string.trim(file.contents("#{credentials}/icecast-source"))

station = "@station@"
holding = "@holding@"

def read_program() =
  try
    let json.parse (p :
      {
        file: string,
        startsAt: float,
        endsAt: float,
        before: {artist: string, title: string},
        after: {artist: string, title: string},
        entries: [{offset: float, artist: string, title: string}]
      }
    ) = file.contents("#{station}/program.json")
    p
  catch err do
    log.important(label="program", "No program, so holding: #{err.message}")
    {
      file="",
      startsAt=0.,
      endsAt=0.,
      before={artist="McTrot radio", title="Off air"},
      after={artist="McTrot radio", title="Off air"},
      entries=[]
    }
  end
end

program = read_program()
show_path = "#{station}/#{program.file}"
has_show = program.file != "" and file.exists(show_path)
if program.file != "" and not has_show then
  log.important(label="program", "#{show_path} isn't there (upload it before program.json), so holding.")
end

# The show airs every day at the program's time, not only on its date:
# today's, if it's on or still to come, else tomorrow's. (Days are 24
# hours, so across a daylight saving change it airs an hour off.)
day = 86400.
started = time()
length = program.endsAt - program.startsAt
latest = program.startsAt + day * floor((started - program.startsAt) / day)
starts = if started >= latest + length then latest + day else latest end
ends = starts + length

on_air_now = has_show and started >= starts and started < ends
cue = if on_air_now then started - starts else 0. end
if on_air_now then
  log.important(label="program", "Joining the show #{cue} s in.")
end

# The show file, cued in to now if it's already on. Without one, the
# holding loop stands in (and the switch below never picks it).
show = single(id="show", if has_show then "annotate:liq_cue_in=#{cue}:#{show_path}" else holding end)
hold = single(id="hold", holding)

def on_air() =
  has_show and time() >= starts and time() < ends
end

# Once today's show is over, stop: systemd starts this again (a second or
# two of silence), which lines up tomorrow's.
if has_show then
  thread.run(delay=ends - started + 1., fun () -> begin
    log.important(label="program", "Today's show is over; restarting for tomorrow's.")
    shutdown()
  end)
end

radio = switch(id="radio", track_sensitive=false, [(on_air, show), ({true}, hold)])

# mksafe: silence rather than nothing if a file can't be read, so
# listeners stay connected.
radio = insert_metadata(mksafe(radio))

# What's on, by the clock: the program's entry now, or its before/after.
count = list.length(program.entries)

def now_playing() =
  t = time()
  if t < starts and has_show then
    (program.before.artist, program.before.title)
  elsif t >= ends or not has_show then
    (program.after.artist, program.after.title)
  else
    offset = t - starts
    # The last entry starting at or before now.
    i = list.length(list.filter(fun (e) -> e.offset <= offset, program.entries)) - 1
    e = list.nth(program.entries, max(0, min(i, count - 1)))
    (e.artist, e.title)
  end
end

# The title last sent out. Switching between show and hold starts a new
# track with the file's own (empty) metadata, so this notices and puts
# the program's back.
sent = ref(("", ""))
radio.on_metadata(synchronous=true, fun (m) -> sent := (m["artist"], m["title"]))

logged = ref(("", ""))

def tick() =
  wanted = now_playing()
  if wanted != sent() then
    let (artist, title) = wanted
    radio.insert_metadata([("artist", artist), ("title", title)])
    sent := wanted
  end
  if wanted != logged() then
    let (artist, title) = wanted
    log.important(label="on air", "#{artist} - #{title}")
    logged := wanted
  end
end

thread.run(every=0.5, tick)

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
