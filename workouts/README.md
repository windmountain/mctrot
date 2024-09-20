When doing cardio for McTrot on the Cybex Arc Trainer, my habit is to just take a photo of the workout summary screen at the end. The tools here are for processing those photos into data.

Summary:

  * Exporting photos from MacOS photos albums
  * Manual data entry based on those photos
  * A bit of cleanup if necessary
  * Visualizing as charts, calendar

Design:
  - Photos of workout results taken with phone
    - saved to "Workout Results" album
    - synced to Mac with iCloud
  - Workout photos imported from MacOS Photos with osxphotos
    $ ./import-photos
  - Server serves a photo with no data captured yet
    - GET /next
    - look at image directory
    - look at collected JSON directory (workouts/*.json)
    - send id for first image without collected JSON
  - Web page shows photo, uses HTML form to accept data entry
  - Server accepts captured data with reference to photo, saves the data
    - PUT /workouts/:id
    - write payload to JSON file (workouts/:id.json)

Cleaning up:
  - Flag photos that aren't Arc trainer workouts by putting 'fff' in any of the fields
  - Once all the photos have a workout record:
    - Find the records containing 'fff'
      - Use their date to find them in Apple Photos
      - Remove them from the "Workout Results" album
      - Delete the workout record
    - Go back to the data entry tool
      - For every image that shows up, delete it by the visible ID in the photos directory
  - Re-import and confirm the data entry tool shows nothing to collect

Compiling:
  - Once the workouts are all in /workouts, run:
    - `./compileWorkouts > workouts.json`

Visualizing:
  - Quick charts:
    - Convert workouts.json to CSV:
      - `cat workouts | ./toCSV`
    - Open the CSV in LibreOffice or similar, make charts (see workouts.ods for example)
  - As highlighted cal output:
    - `cat workouts.json | ./toDates | ./toHighlightedCalendar`
