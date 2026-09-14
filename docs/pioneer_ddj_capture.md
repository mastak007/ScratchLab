# Pioneer DDJ capture inputs

SL Capture exposes three separate Pioneer controller choices in Capture Setup:

- DDJ-REV5 — four MIDI deck channels, top jog scratch motion on CC34 in vinyl mode, channel fader CC19/51, crossfader CC31/63 on MIDI channel 7.
- DDJ-REV7 — two MIDI deck channels, motorized top jog scratch motion on CC34 in vinyl mode, channel fader CC19/51, crossfader CC31/63 on MIDI channel 7.
- DDJ-FLX10 — four MIDI deck channels, top jog scratch motion on CC34 in vinyl mode, channel fader CC19/51, crossfader CC31/63 on MIDI channel 7.

The profiles are model-specific and marked heuristic. The official MIDI lists define the addresses, but a connected unit still needs guided verification because firmware, deck selection, vinyl mode, direction, and the audio route are runtime facts. Choosing a profile does not certify a capture or bypass existing readiness and export gates.

Official references: [DDJ-REV5 MIDI messages](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev5/ddj-rev5_midi_message_list_e1.pdf), [DDJ-REV7 MIDI messages](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev7/ddj-rev7_midi_message_list_e2.pdf), and [DDJ-FLX10 MIDI messages](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx10/ddj-flx10_midi_message_list_e1.pdf).
