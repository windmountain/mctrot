const express = require('express');
const fs = require('fs');
const path = require('path');

const app = express();

app.use('/photos', express.static('photos'))
app.use(express.json())

const htmlFile = path.join(process.cwd(), 'data-entry.html');
const photosDir = path.join(process.cwd(), 'photos')
const workoutsDir = path.join(process.cwd(), 'workouts')
const workoutFile = (id) => path.join(process.cwd(), 'workouts', `${id}.json`);

const getPhotos = () => fs.readdirSync(photosDir)
    .filter((fileName) => fileName.endsWith('jpg'))
    .map((fileName) => fileName.split('.')[0]);

const getWorkouts = () => fs.readdirSync(workoutsDir)
    .filter((fileName) => fileName.endsWith('json'))
    .map((fileName) => fileName.split('.')[0]);

getFirstUnlabeledWorkoutPhoto = () => {
  const p = getPhotos();
  const w = getWorkouts();
  // replace with set difference when nodejs_22 comes to devenv?
  for(var i = 0; i < p.length; i++) {
    if(!w.includes(p[i])) {
      return p[i];
    }
  }
}

app.get('/', (req, res) => {
  res.sendFile(htmlFile);
});

app.get('/next', (req, res) => {
  const next = getFirstUnlabeledWorkoutPhoto();
  res.send(next);
});

app.put('/workout/:id', (req, res) => {
  const data = JSON.stringify(req.body, null, 2);
  fs.writeFileSync(workoutFile(req.params.id), data);
  res.send('ok');
});

const port = 3003;
console.log(`Listening on port ${port}`)
app.listen(port);
