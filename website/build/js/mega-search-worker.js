// One mega search worker (see mega-search.html): runs each job it's sent
// through the compiled MegaSearchWorker Elm program and posts back the
// result. build.sh compiles that program next to this file.
importScripts("mega-search-worker-elm.js");

var app = Elm.MegaSearchWorker.init();

app.ports.done.subscribe(function (result) {
  postMessage(result);
});

onmessage = function (e) {
  app.ports.job.send(e.data);
};
