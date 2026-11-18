package main

import snd "shared:iv_snd"

// ---------------------------------------------------------------------------
// The project: what the editor edits.
//
// It is the library's score (iv_snd/score.odin): a list of tracks, each one sequence of notes with its own instrument and
// mixer settings, plus the tempo, the loop and the instruments (which carry their effect graphs). The editor
// only gives the model short names. There are no channels and no controller numbers in it: those exist only in
// the Song the sequencer plays, which project_to_song makes whenever it is needed (and which has every channel
// the tracks need handed out for it).
// ---------------------------------------------------------------------------

Name :: snd.Score_Name
Note :: snd.Score_Note
Trk :: snd.Score_Track
Project :: snd.Score
Song_Mode :: snd.Score_Mode
Mix_Field :: snd.Mix_Field

name_make :: snd.score_name_make
name_str :: snd.score_name_str

project_free :: snd.score_free
project_clone :: snd.score_clone
project_new :: snd.score_new
project_from_song :: snd.score_from_song
project_to_song :: snd.score_to_song
project_end :: snd.score_end
project_prune_instruments :: snd.score_prune_instruments
project_prune_samples :: snd.score_prune_samples
