const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SUPPORTED_AUDIO_EXTENSIONS = new Set(['.wav', '.wave', '.aif', '.aiff', '.mp3']);
const CREATE_PROJECT_REGION_GAP_SECONDS = 60;
const CREATE_PROJECT_INTERNAL_PEAK_DB = -1;
const CREATE_PROJECT_DESTINATION_EXISTS_MESSAGE = 'Não é possível criar este projeto. Já existe outro projeto com esse nome nessa pasta.';
const CREATE_PROJECT_TRACK_RULES = [
  { name: 'Click', pattern: /\b(click|metronomo|metronome)\b/ },
  { name: 'Regência', pattern: /\b(regencia|maestro|gps|contagem|count in|countin)\b/ },
  { name: 'Backing Vocal', pattern: /\b(back(?:ing)?(?: vocals?| vocais| vozes?| voz)?|backs?|bk|bgv)\b/ },
  // O nome da pista pode vir acompanhado pelo título da música, pelo artista
  // ou por uma seção. A correspondência deve funcionar em qualquer parte
  // do nome, assim como já acontece com as demais pistas.
  { name: 'Vox Synth', pattern: /\b(synth vox|syn ?vox|air vox|space voices?|vocal airy|vox synth|d ?50 voices?|vocal oohz|spaced voxx?|wavox)\b/ },
  { name: 'Vocal', pattern: /\bvocals?\b/ },
  { name: 'Vox', pattern: /\bvox\b/ },
  { name: 'Guia', pattern: /\b(guia|guide|voz|vz)\b/ },
  { name: 'Sanfona', pattern: /\b(sanfona|acordeon|accordion)\b/ },
  { name: 'Ukulele', pattern: /\b(ukulele|ukelele|uke)\b/ },
  { name: 'Cavaquinho', pattern: /\b(cavaquinho|cavaquinhos|cavaco|cavacos)\b/ },
  { name: 'Banjo', pattern: /\b(banjo|banjos)\b/ },
  { name: 'Bandolim', pattern: /\b(bandolim|bandolins|mandolin|mandolins)\b/ },
  { name: 'Violão Nylon', pattern: /\b(vl nylon|violao nylon|nylon guitar|nylon)\b/ },
  { name: 'Violão', pattern: /\b(violao|acoustic guitar|acoustic)\b/ },
  { name: 'Guitarra', pattern: /\b(guitarras?|guitars?|gtr|guita|guit)\b/ },
  { name: 'Baixo', pattern: /\b(baixo|bass)\b/ },
  { name: 'Bumbo', pattern: /\b(bumbos?|kicks?|bass drums?|gran cassa|bd)\b/ },
  { name: 'Caixa', pattern: /\b(caixas?|snares?|cx)\b/ },
  { name: 'Hi-Hat', pattern: /\b(hi ?hats?|hihats?|chimbal|chimbais|chimbaus?|ximbal|ximbais|ximbaus?|hh)\b/ },
  { name: 'Surdo', pattern: /\b(surdos?|sd|floor ?toms?)\b/ },
  { name: 'Tom', pattern: /\b(tom ?toms?|tomtoms?|tontons?|rontons?|toms?)\b/ },
  { name: 'Over', pattern: /\b(overs?|overheads?|ohs?)\b/ },
  { name: 'Ride', pattern: /\b(rides?)\b/ },
  { name: 'Crash', pattern: /\b(crash(?:es)?)\b/ },
  { name: 'Reverse Cymbal', pattern: /\b(reverse cymbals?|rev cymbals?|revcymbl)\b/ },
  { name: 'Pratos', pattern: /\b(prato|pratos|cymbals?|cymbs?|cym)\b/ },
  { name: 'Conga', pattern: /\b(congas?|tumbadoras?|cg)\b/ },
  { name: 'Bongo', pattern: /\b(bongos?|bg)\b/ },
  { name: 'Timbal', pattern: /\b(timbal|timbau|timbales?)\b/ },
  { name: 'Repique de Mão', pattern: /\b(repique de mao|hand repique)\b/ },
  { name: 'Repique', pattern: /\b(repique|repinique|repiniques?)\b/ },
  { name: 'Meia Lua', pattern: /\b(meia lua|half moon(?: tambourine)?)\b/ },
  { name: 'Pandeiro', pattern: /\b(pandeiro|pandeiros|tambourine|tambourines)\b/ },
  { name: 'Pandeirola', pattern: /\b(pandeirola|pandeirolas)\b/ },
  { name: 'Bacurinha', pattern: /\b(bacurinha|bacurinhas)\b/ },
  { name: 'Tamborim', pattern: /\b(tamborim|tamborins)\b/ },
  { name: 'Shaker', pattern: /\b(shaker|shakers)\b/ },
  { name: 'Ganzá', pattern: /\b(ganza|ganzas)\b/ },
  { name: 'Agogô', pattern: /\b(agogo|agogos|sambago bells?)\b/ },
  { name: 'Cowbell', pattern: /\b(cowbell|cowbells|cow bell|cow bells)\b/ },
  { name: 'Clave', pattern: /\b(clave|claves)\b/ },
  { name: 'Triângulo', pattern: /\b(triangulo|triangle)\b/ },
  { name: 'Cajón', pattern: /\b(cajon|cajons)\b/ },
  { name: 'Djembe', pattern: /\b(djembe|djembes)\b/ },
  { name: 'Darbuka', pattern: /\b(darbuka|darabuka|doumbek)\b/ },
  { name: 'Cabasa', pattern: /\b(cabasa|cabassa)\b/ },
  { name: 'Maracas', pattern: /\b(maraca|maracas)\b/ },
  { name: 'Chocalho', pattern: /\b(chocalhos?|rattles?|jingle bells?|sleigh bells?)\b/ },
  { name: 'Cuíca', pattern: /\b(cuica|cuicas)\b/ },
  { name: 'Berimbau', pattern: /\b(berimbau|berimbaus)\b/ },
  { name: 'Caxixi', pattern: /\b(caxixi|caxixis)\b/ },
  { name: 'Reco-Reco', pattern: /\b(reco reco|recoreco|guiros?|gueros?|guiras?)\b/ },
  { name: 'Afoxé', pattern: /\b(afoxe|afoxes)\b/ },
  { name: 'Alfaia', pattern: /\b(alfaia|alfaias)\b/ },
  { name: 'Zabumba', pattern: /\b(zabumba|zabumbas)\b/ },
  { name: 'Atabaque', pattern: /\b(atabaque|atabaques)\b/ },
  { name: 'Tantã', pattern: /\b(tanta|tantan|tan tan)\b/ },
  { name: 'Rebolo', pattern: /\b(rebolo|rebolos)\b/ },
  { name: 'Sopapo', pattern: /\b(sopapo|sopapos)\b/ },
  { name: 'Tarol', pattern: /\b(tarol|tarols)\b/ },
  { name: 'Xequerê', pattern: /\b(xequeres?|shekeres?|chequeres?)\b/ },
  { name: 'Rocar', pattern: /\b(rocar|rocar)\b/ },
  { name: 'Palmas', pattern: /\b(palmas|hand clap|handclap|claps?)\b/ },
  { name: 'Snap', pattern: /\b(finger snap|snap|snaps)\b/ },
  { name: 'Rimshot', pattern: /\b(rimshot|rim shot|rim)\b/ },
  { name: 'Tímpano', pattern: /\b(timpano|timpani|kettle drum)\b/ },
  { name: 'Tabla', pattern: /\b(tabla|tablas)\b/ },
  { name: 'Taiko', pattern: /\b(taikos?|taiko drums?|wadaiko)\b/ },
  { name: 'Tambora', pattern: /\b(tamboras?|dominican drums?)\b/ },
  { name: 'Bodhrán', pattern: /\b(bodhran|bodhrans)\b/ },
  { name: 'Frame Drum', pattern: /\b(frame drums?|tambores? de moldura)\b/ },
  { name: 'Talking Drum', pattern: /\b(talking drums?)\b/ },
  { name: 'Gong', pattern: /\b(gong|gongs)\b/ },
  { name: 'Jamblock', pattern: /\b(jam ?blocks?|jamblocks?)\b/ },
  { name: 'Bloco', pattern: /\b(blast blocks?|granite blocks?|temple blocks?|blocks? de percussao)\b/ },
  { name: 'Woodblock', pattern: /\b(woodblock|wood block|wood blocks)\b/ },
  { name: 'Bar Chimes', pattern: /\b(bar chimes?|mark trees?|wind chimes?)\b/ },
  { name: 'Bell Tree', pattern: /\b(bell trees?)\b/ },
  { name: 'Waterfall', pattern: /\b(percussion waterfalls?|waterfall percussion|waterfalls?)\b/ },
  { name: 'Vibraslap', pattern: /\b(vibraslap|vibra slap)\b/ },
  { name: 'Castanholas', pattern: /\b(castanholas?|castanets?)\b/ },
  { name: 'Apito', pattern: /\b(apito|apitos|whistle|whistles)\b/ },
  { name: 'Udu', pattern: /\b(udu|udus)\b/ },
  { name: 'Marimba', pattern: /\b(marimba|marimbas)\b/ },
  { name: 'Vibrafone', pattern: /\b(vibrafone|vibraphone|vibes)\b/ },
  { name: 'Xilofone', pattern: /\b(xilofone|xylophone)\b/ },
  { name: 'Kalimba', pattern: /\b(kalimba|kalimbas)\b/ },
  { name: 'Steel Pan', pattern: /\b(steel pan|steelpan|steel drum)\b/ },
  { name: 'Handpan', pattern: /\b(handpan|handpans|hang drum)\b/ },
  { name: 'Bateria', pattern: /\b(baterias?|bateras?|drums?|drum ?kits?|drum ?sets?|drumsets?|kit de bateria|(?:606|707|808|909) ?kits?|linndrum|drum machine)\b/ },
  { name: 'Rhodes', pattern: /\b(rhodes|rhode)\b/ },
  { name: 'Wurlitzer', pattern: /\b(wurlitzer|wurli|wurly)\b/ },
  { name: 'Electric Piano', pattern: /\b(electric piano|e piano|ep)\b/ },
  { name: 'CP80', pattern: /\b(cp ?80)\b/ },
  { name: 'DX', pattern: /\b(dx(?: ?(?:1|5|7|9|11|21|27|100))?|dx (?:piano|ep|e piano|keys?|synth)|fm (?:piano|ep|e piano|keys?)|tx ?816)\b/ },
  { name: 'Honky Tonk', pattern: /\b(honky tonk|honkytonk)\b/ },
  { name: 'Clavi', pattern: /\b(clavinet|clavi|clav)\b/ },
  { name: 'Hammond', pattern: /\b(hammond|b ?3 organ|b ?3)\b/ },
  { name: 'Piano', pattern: /\b(piano|pno)\b/ },
  { name: 'Órgão', pattern: /\b(orgao|organ|orgn)\b/ },
  { name: 'Cravo', pattern: /\b(cravo|harpsichord|harpsi)\b/ },
  { name: 'Celesta', pattern: /\b(celesta|celeste)\b/ },
  { name: 'Glockenspiel', pattern: /\b(glockenspiel|glock)\b/ },
  { name: 'Music Box', pattern: /\b(music box|caixinha de musica)\b/ },
  { name: 'Bells', pattern: /\b(bell|bells|sino|sinos)\b/ },
  { name: 'Mallet', pattern: /\b(mallet|mallets)\b/ },
  { name: 'Synth Brass', pattern: /\b(synth brass|syn brass|synthbrass|syn ?brss|syn ?brs|sy ?brs|polybrss|poly brass|analog brass|slap brass|rich brass|flutish brass|velo brass|brass attack|horn blast|mks ?80 brass|(?:d ?50|juno(?: ?(?:60|106))?|jupiter(?: ?8)?|jp ?(?:6|8|8000)|jx|jd ?(?:80|800)|jv ?1080|xv ?5080|m ?1|triton|trinity|kronos|krome|kross|korg) (?:soft )?brass)\b/ },
  { name: 'Synth Strings', pattern: /\b(synth strings?|syn strings?|synthstrings|syn ?str(?:ings?)?|(?:d ?50|juno(?: ?(?:6|60|106))?|jupiter(?: ?8)?|jp ?(?:6|8|8000)|jx|jd ?(?:80|800)) (?:slow )?str(?:ings?)?)\b/ },
  { name: 'Saw', pattern: /\b(saw|sawtooth)\b/ },
  { name: 'Square', pattern: /\b(square|square wave)\b/ },
  { name: 'Pulse', pattern: /\b(pulse|pulse wave)\b/ },
  { name: 'Pad', pattern: /\b(pads?|d ?50 heaven|d ?50 stack pad|(?:sft|brt|choir|syn|str|bell|vox|jup ?8|jp ?8) ?pd)\b/ },
  { name: 'Synth', pattern: /\b(synth|synthesizer|sintetizador|fast synth|slow synth|motion synth|poly ?synth|pulsating)\b/ },
  { name: 'Lead', pattern: /\b(leads?|(?:sft|syn|synth|saw|square|sqr|mono|jp ?6|jp ?8|juno) ?ld)\b/ },
  { name: 'Pluck', pattern: /\b(pluck|plucked)\b/ },
  { name: 'Arp', pattern: /\b(arp|arpeggio|arpejo)\b/ },
  { name: 'Teclado', pattern: /\b(teclado|keyboard|keys?|poly ?keys?|polykey)\b/ },
  { name: 'Cordas', pattern: /\b(cordas|strings?)\b/ },
  { name: 'Hit', pattern: /\b(orch ?hits?|orchhits?|orchestra ?hits?|orchestral ?hits?|orquestra ?hits?|orquestral ?hits?|orq ?hits?|orqhits?|brass ?hits?|double ?hits?|euro ?hits?|impact|stabs?|hits?)\b/ },
  { name: 'Percussão', pattern: /\b(percussao|percussion|perc)\b/ },
  { name: 'Metais', pattern: /(?:\b(metais|naipe(?: de metais)?|nipe(?: de metais)?|brass(?: sections?| ensembles?| falls?)?|brss ?sec(?:t(?:ion)?)?s?|brss ?falls?|sopros?|horn ?(?:sections?|orchestra|orch|swell)|hornorch|(?:noble|massed|afro) horns?|sax sections?|trumpet (?:and|&) trombone sections?|tp ?(?:and|&) ?tb ?sec(?:t(?:ion)?)?s?)\b|^horns?(?=\s+(?:l|r|\d+)\b|$))/ },
  { name: 'Trompete Piccolo', pattern: /\b(trompete piccolo|piccolo trumpet)\b/ },
  { name: 'Trompete Baixo', pattern: /\b(trompete baixo|bass trumpet)\b/ },
  { name: 'Trompete', pattern: /\b(trompetes?|trumpets?|muted trumpet|mute trp|warm trp|trp|tpt)\b/ },
  { name: 'Corneta', pattern: /\b(cornetas?|cornets?)\b/ },
  { name: 'Flugelhorn', pattern: /\b(flugelhorns?|flugels?|fliscornes?|flicornes?)\b/ },
  { name: 'Trombone Baixo', pattern: /\b(trombone baixo|bass trombone)\b/ },
  { name: 'Trombone Alto', pattern: /\b(trombone alto|alto trombone)\b/ },
  { name: 'Trombone Tenor', pattern: /\b(trombone tenor|tenor trombone)\b/ },
  { name: 'Trombone', pattern: /\b(trombones?|valve trombone|tbn)\b/ },
  { name: 'Sax Soprano', pattern: /\b(sax(?:ofone)? soprano|soprano sax(?:ophone)?|sprno ?sax)\b/ },
  { name: 'Sax Alto', pattern: /\b(sax(?:ofone)? alto|alto sax(?:ophone)?)\b/ },
  { name: 'Sax Tenor', pattern: /\b(sax(?:ofone)? tenor|tenor sax(?:ophone)?)\b/ },
  { name: 'Sax Barítono', pattern: /\b(sax(?:ofone)? baritono|baritone sax(?:ophone)?|bari ?sax)\b/ },
  { name: 'Sax', pattern: /\b(saxes|sax|saxofones?|saxophones?)\b/ },
  { name: 'Tuba', pattern: /\b(tuba|tubas)\b/ },
  { name: 'Sousafone', pattern: /\b(sousafones?|sousaphones?)\b/ },
  { name: 'Bombardino', pattern: /\b(bombardinos?|eufonios?|euphoniums?)\b/ },
  { name: 'Barítono de Metal', pattern: /\b(baritono de metal|baritone horns?|marching baritones?)\b/ },
  { name: 'Trompa Alto', pattern: /\b(trompa (?:alto|tenor)|alto horns?|tenor horns?)\b/ },
  { name: 'Mellophone', pattern: /\b(mellophones?|melofones?)\b/ },
  { name: 'Trompa', pattern: /\b(trompas?|french horns?|fr ?horns?|corno frances)\b/ },
  { name: 'Clarim', pattern: /\b(clarins?|bugles?)\b/ },
  { name: 'Shofar', pattern: /\b(shofars?|shofarot|shofroth|schofars?)\b/ },
  { name: 'Piccolo', pattern: /\b(piccolo)\b/ },
  { name: 'Flauta Pan', pattern: /\b(flauta pan|pan flute)\b/ },
  { name: 'Flauta', pattern: /\b(flauta|flute)\b/ },
  { name: 'Clarinete', pattern: /\b(clarinete|clarinet)\b/ },
  { name: 'Oboé', pattern: /\b(oboe)\b/ },
  { name: 'Fagote', pattern: /\b(fagote|bassoon)\b/ },
  { name: 'Recorder', pattern: /\b(recorder)\b/ },
  { name: 'Ocarina', pattern: /\b(ocarina)\b/ },
  { name: 'Harmônica', pattern: /\b(harmonica|gaita de boca)\b/ },
  { name: 'Violino', pattern: /\b(violino|violin|fiddle)\b/ },
  { name: 'Viola', pattern: /\b(viola)\b/ },
  { name: 'Cello', pattern: /\b(cello|violoncelo)\b/ },
  { name: 'Harpa', pattern: /\b(harpa|harp)\b/ },
  { name: 'Sitar', pattern: /\b(sitar)\b/ },
  { name: 'Koto', pattern: /\b(koto|shamisen)\b/ },
  { name: 'Orquestra', pattern: /\b(orquestra|orchestra|ensemble)\b/ },
  { name: 'Coro', pattern: /\b(coro|choir)\b/ },
  { name: 'Sequencer', pattern: /\b(sequencer|sequence|sequencia|sequenciador|seq)\b/ },
  { name: 'FX', pattern: /\b(fx|sfx|efeito|efeitos)\b/ },
  { name: 'Loop', pattern: /\b(loop)\b/ },
  { name: 'Playback', pattern: /\b(playback|pb)\b/ },
  { name: 'Solo', pattern: /\bsolo\b/ },
  { name: 'Vinheta', pattern: /\b(vinheta|vinhetas)\b/ },
  { name: 'Universe', pattern: /\b(universe)\b/ },
  { name: 'Fantasia', pattern: /\b(fantasia(?: jv)?|fantasy)\b/ },
  { name: 'Staccato Heaven', pattern: /\b((?:staccato|stac) heaven)\b/ },
  { name: 'Digital Native Dance', pattern: /\b(digital native dance|native dance)\b/ },
  { name: 'Pizzagogo', pattern: /\b(pizzagogo)\b/ },
  { name: 'Glass Voices', pattern: /\b(glass voices?|glass vox)\b/ },
  { name: 'Soundtrack', pattern: /\b(sound ?track)\b/ },
  { name: 'M1', pattern: /\b(?:korg )?m ?1\b/ },
  { name: 'Triton', pattern: /\b(?:korg )?triton(?: studio| le| extreme| rack)?\b/ },
  { name: 'Trinity', pattern: /\b(?:korg )?trinity\b/ },
  { name: 'Kronos', pattern: /\b(?:korg )?kronos\b/ },
  { name: 'Nautilus', pattern: /\b(?:korg )?nautilus\b/ },
  { name: 'Krome', pattern: /\b(?:korg )?krome\b/ },
  { name: 'Kross', pattern: /\b(?:korg )?kross(?: ?2)?\b/ },
  { name: 'Wavestation', pattern: /\b(?:korg )?wavestation\b/ },
  { name: 'Wavestate', pattern: /\b(?:korg )?wavestate\b/ },
  { name: 'Polysix', pattern: /\b(?:korg )?polysix\b/ },
  { name: 'MS-20', pattern: /\b(?:korg )?ms ?20\b/ },
  { name: 'Opsix', pattern: /\b(?:korg )?opsix\b/ },
  { name: 'Modwave', pattern: /\b(?:korg )?modwave\b/ },
  { name: 'Minilogue', pattern: /\b(?:korg )?minilogue(?: xd)?\b/ },
  { name: 'KingKORG', pattern: /\bking ?korg\b/ },
  { name: 'Korg PA', pattern: /\b(?:korg )?pa ?(?:5 x|4 x|1000|700|600)\b/ },
  { name: 'Korg', pattern: /\bkorg\b/ },
  { name: 'D-50', pattern: /\b(?:roland )?d ?50\b/ },
  { name: 'JD-800', pattern: /\b(?:roland )?jd ?(?:80|800|990|08)\b/ },
  { name: 'JV-1080', pattern: /\b(?:roland )?jv ?(?:1080|2080)\b/ },
  { name: 'XV-5080', pattern: /\b(?:roland )?xv ?(?:5050|5080)\b/ },
  { name: 'XP', pattern: /\b(?:roland )?xp ?(?:30|50|60|80)\b/ },
  { name: 'Juno', pattern: /\b(?:roland )?juno(?: ?(?:6|60|106|x|x m|ds))?\b/ },
  { name: 'Jupiter', pattern: /\b(?:roland )?(?:jupiter(?: ?(?:6|8|x|x m))?|jp ?(?:6|8|8000))\b/ },
  { name: 'Fantom', pattern: /\b(?:roland )?fantom(?: ?(?:06|07|08|6|7|8|g|x))?\b/ },
  { name: 'Integra-7', pattern: /\b(?:roland )?integra ?7\b/ },
  { name: 'RD', pattern: /\b(?:roland )?rd ?(?:1000|2000|700|800|88)\b/ },
  { name: 'SH-101', pattern: /\b(?:roland )?sh ?(?:101|2|4 d)\b/ },
  { name: 'JX', pattern: /\b(?:roland )?jx ?(?:3 p|8 p|08)\b/ },
  { name: 'System-8', pattern: /\b(?:roland )?system ?8\b/ },
  { name: 'Roland', pattern: /\broland\b/ }
];

const CREATE_PROJECT_TRACK_GROUPS = [
  { key: 'interno', name: 'Interno', trackNames: new Set(['Regência', 'Click', 'Guia']) },
  { key: 'guitarras', name: 'Guitarras', trackNames: new Set(['Guitarra']) },
  { key: 'violoes', name: 'Violões', trackNames: new Set(['Violão', 'Violão Nylon', 'Ukulele', 'Cavaquinho', 'Banjo', 'Bandolim']) },
  { key: 'sanfonas', name: 'Sanfonas', trackNames: new Set(['Sanfona']) },
  {
    key: 'teclados',
    name: 'Teclados',
    trackNames: new Set(['Teclado', 'Piano', 'Rhodes', 'Wurlitzer', 'Electric Piano', 'CP80', 'DX', 'Honky Tonk', 'Clavi', 'Hammond', 'Órgão', 'Cravo', 'Celesta', 'Glockenspiel', 'Music Box', 'Bells', 'Mallet', 'Synth Brass', 'Synth Strings', 'Saw', 'Square', 'Pulse', 'Pad', 'Vox Synth', 'Synth', 'Lead', 'Pluck', 'Arp', 'Cordas', 'Hit', 'Universe', 'Fantasia', 'Staccato Heaven', 'Digital Native Dance', 'Pizzagogo', 'Glass Voices', 'Soundtrack', 'M1', 'Triton', 'Trinity', 'Kronos', 'Nautilus', 'Krome', 'Kross', 'Wavestation', 'Wavestate', 'Polysix', 'MS-20', 'Opsix', 'Modwave', 'Minilogue', 'KingKORG', 'Korg PA', 'Korg', 'D-50', 'JD-800', 'JV-1080', 'XV-5080', 'XP', 'Juno', 'Jupiter', 'Fantom', 'Integra-7', 'RD', 'SH-101', 'JX', 'System-8', 'Roland'])
  },
  {
    key: 'metais',
    name: 'Metais',
    trackNames: new Set(['Metais', 'Trompete Piccolo', 'Trompete Baixo', 'Trompete', 'Corneta', 'Flugelhorn', 'Trombone Baixo', 'Trombone Alto', 'Trombone Tenor', 'Trombone', 'Sax Soprano', 'Sax Alto', 'Sax Tenor', 'Sax Barítono', 'Sax', 'Tuba', 'Sousafone', 'Bombardino', 'Barítono de Metal', 'Trompa Alto', 'Mellophone', 'Trompa', 'Clarim', 'Shofar'])
  },
  {
    key: 'percussivo',
    name: 'Percussivo',
    trackNames: new Set(['Bumbo', 'Caixa', 'Hi-Hat', 'Tom', 'Over', 'Reverse Cymbal', 'Pratos', 'Ride', 'Crash', 'Conga', 'Bongo', 'Timbal', 'Surdo', 'Repique de Mão', 'Repique', 'Meia Lua', 'Pandeiro', 'Pandeirola', 'Bacurinha', 'Tamborim', 'Shaker', 'Ganzá', 'Agogô', 'Cowbell', 'Clave', 'Triângulo', 'Cajón', 'Djembe', 'Darbuka', 'Cabasa', 'Maracas', 'Chocalho', 'Cuíca', 'Berimbau', 'Caxixi', 'Reco-Reco', 'Afoxé', 'Alfaia', 'Zabumba', 'Atabaque', 'Tantã', 'Rebolo', 'Sopapo', 'Tarol', 'Xequerê', 'Rocar', 'Palmas', 'Snap', 'Rimshot', 'Tímpano', 'Tabla', 'Taiko', 'Tambora', 'Bodhrán', 'Frame Drum', 'Talking Drum', 'Gong', 'Jamblock', 'Bloco', 'Woodblock', 'Bar Chimes', 'Bell Tree', 'Waterfall', 'Vibraslap', 'Castanholas', 'Apito', 'Udu', 'Bateria', 'Percussão'])
  },
  { key: 'back-vocais', name: 'Back Vocais', trackNames: new Set(['Backing Vocal', 'Vocal', 'Vox', 'Coro']) },
  { key: 'outros', name: 'Outros', trackNames: null }
];

const CREATE_PROJECT_GROUP_COLOR_PALETTE = [
  { red: 255, green: 105, blue: 105 },
  { red: 255, green: 184, blue: 76 },
  { red: 104, green: 211, blue: 145 },
  { red: 74, green: 190, blue: 230 },
  { red: 117, green: 137, blue: 255 },
  { red: 202, green: 112, blue: 255 },
  { red: 240, green: 105, blue: 180 },
  { red: 205, green: 218, blue: 70 },
  { red: 90, green: 220, blue: 205 }
];

const TRACK_PRIORITY = new Map(CREATE_PROJECT_TRACK_RULES.map((rule, index) => [rule.name, index]));
const KEYBOARD_MODEL_REFERENCE_PATTERN = /\b(?:korg|roland|m ?1|triton(?: studio| le| extreme| rack)?|trinity|kronos|nautilus|krome|kross(?: ?2)?|wavestation|wavestate|polysix|ms ?20|opsix|modwave|minilogue(?: xd)?|king ?korg|pa ?(?:5 x|4 x|1000|700|600)|d ?50|jd ?(?:80|800|990|08)|jv ?(?:1080|2080)|xv ?(?:5050|5080)|xp ?(?:30|50|60|80)|juno(?: ?(?:6|60|106|x|xm|x m|ds))?|jupiter(?: ?(?:6|8|x|xm|x m))?|jp ?(?:6|8|8000)|fantom(?: ?(?:06|07|08|6|7|8|g|x))?|integra ?7|rd ?(?:1000|2000|700|800|88)|sh ?(?:101|2|4 d)|jx ?(?:3 p|8 p|08)|system ?8)\b/g;

function normalizeWords(value) {
  return String(value || '')
    .replace(/([a-zà-ÿ])([A-Z])/g, '$1 $2')
    .replace(/([A-Za-zÀ-ÿ])(\d)/g, '$1 $2')
    .replace(/(\d)([A-Za-zÀ-ÿ])/g, '$1 $2')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[_.,()[\]{}]+/g, ' ')
    .replace(/\s*[-–—]+\s*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizeTrackKey(value) {
  return normalizeWords(value).replace(/\s+/g, ' ');
}

// Marcas e plataformas que costumam vir junto do nome da pasta baixada. A
// comparação é feita com o texto normalizado e com a expressão inteira para
// não remover palavras genéricas de títulos reais (por exemplo: "Loop de
// Amor", "Primeiro Amor", "Worship You" ou "Studio 54").
const SONG_FOLDER_SOURCE_LABEL_PATTERN_SOURCE = [
  'vs\\s+(?:professional|profissional|premium|pro|sertanejo|gospel)',
  'clube\\s+(?:do|de)\\s+vs',
  'playback\\s+(?:professional|studio)',
  'pacote\\s+vs',
  'multi\\s*tracks\\s+for\\s+worship',
  'multi\\s*tracks(?:\\s+com(?:\\s+br)?)?',
  'loop\\s*community(?:\\s+com)?',
  'prime\\s+by\\s+loop\\s*community',
  'praise\\s*charts(?:\\s+com)?',
  'worship\\s*backing\\s*(?:tracks|band)(?:\\s+com)?',
  'custom\\s*backing\\s*tracks(?:\\s+(?:com|net))?',
  'karaoke\\s*version(?:\\s+com)?',
  'song\\s*galaxy(?:\\s+com)?',
  'jam\\s*zone(?:\\s+com)?',
  'jam\\s*kazam(?:\\s+com)?',
  'hit\\s*trax',
  'supreme\\s+(?:tracks|midi|network)',
  'midi\\s*art(?:\\s+store)?',
  'extreme\\s+backing\\s*tracks',
  'jetset\\s+sound',
  'shred\\s*trax'
].join('|');

const SONG_FOLDER_LABEL_PATTERN = new RegExp(
  `^(?:www\\s+)?(?:${SONG_FOLDER_SOURCE_LABEL_PATTERN_SOURCE})(?:\\s+(?:com(?:\\s+(?:br|au))?|co\\s+uk|net|org|store|ca))?(?:\\s+\\d{2,4})?$`,
  'i'
);

// Shared with Hook Rename suggestions. Track vocabulary and download-source
// labels are separate taxonomies: removing a provider tag must stay possible.
const SONG_FOLDER_EMBEDDED_LABEL_PATTERN = new RegExp(
  `\\b(?:${SONG_FOLDER_SOURCE_LABEL_PATTERN_SOURCE})\\b`, 'gi'
);

function isCreateProjectSourceLabel(value) {
  return SONG_FOLDER_LABEL_PATTERN.test(normalizeWords(value));
}

function isCreateProjectTrackLabel(value) {
  const normalized = normalizeWords(value);
  if (!normalized || isCreateProjectSourceLabel(normalized)) return false;
  return CREATE_PROJECT_TRACK_RULES.some((rule) => {
    const match = normalized.match(rule.pattern);
    return match && match[0] === normalized;
  });
}

function containsCreateProjectTrackName(value) {
  const normalized = normalizeWords(value)
    .replace(SONG_FOLDER_EMBEDDED_LABEL_PATTERN, ' ').replace(/\s+/g, ' ').trim();
  if (!normalized) return false;
  // Check both the phrase (Electric Piano, Hi-Hat...) and its words so that
  // anchored aliases such as Vocal/Vox also stay out of mixed suggestions.
  const candidates = [normalized, ...normalized.split(' ')];
  return candidates.some((candidate) =>
    CREATE_PROJECT_TRACK_RULES.some((rule) => rule.pattern.test(candidate)));
}

// Versão para reconhecer as mesmas marcas no começo/fim do texto original,
// preservando pontos e hífens de domínios como MultiTracks.com.br.
const SONG_FOLDER_RAW_LABEL_PATTERN_SOURCE = [
  'vs\\s+(?:professional|profissional|premium|pro|sertanejo|gospel)',
  'clube\\s+(?:do|de)\\s+vs',
  'playback\\s+(?:professional|studio)',
  'pacote\\s+vs',
  'multi\\s*tracks\\s+for\\s+worship',
  'multi\\s*tracks(?:\\s*\\.\\s*com(?:\\s*\\.\\s*br)?)?',
  'loop\\s*community(?:\\s*\\.\\s*com)?',
  'prime\\s+by\\s+loop\\s*community',
  'praise\\s*charts(?:\\s*\\.\\s*com)?',
  'worship\\s*backing\\s*(?:tracks|band)(?:\\s*\\.\\s*com)?',
  'custom\\s*backing\\s*tracks(?:\\s*\\.\\s*(?:com|net))?',
  'karaoke\\s*[- ]?\\s*version(?:\\s*\\.\\s*com)?',
  'song\\s*galaxy(?:\\s*\\.\\s*com)?',
  'jam\\s*zone(?:\\s*\\.\\s*com)?',
  'jam\\s*kazam(?:\\s*\\.\\s*com)?',
  'hit\\s*trax',
  'supreme\\s*[- ]?\\s*(?:tracks|midi|network)',
  'midi\\s*art(?:\\s*\\.\\s*store)?',
  'extreme\\s+backing\\s*tracks',
  'jetset\\s+sound',
  'shred\\s*trax'
].join('|');

function inferSongNameFromFolder(folderPathOrName) {
  const rawName = path.basename(String(folderPathOrName || '')).trim();
  const removedLabels = [];
  let working = rawName
    .replace(/[\[(]([^\])]+)[\])]/g, (full, content) => {
      if (!SONG_FOLDER_LABEL_PATTERN.test(normalizeWords(content))) return full;
      removedLabels.push(content.trim());
      return ' ';
    })
    .replace(/^\s*\d{1,3}\s*[.)_-]+\s*/, '')
    .trim();

  const pieces = working.split(/\s+(?:-|–|—|\||•)\s+|\s*_{2,}\s*/).filter(Boolean);
  const titlePieces = pieces.filter((piece) => {
    if (!SONG_FOLDER_LABEL_PATTERN.test(normalizeWords(piece))) return true;
    removedLabels.push(piece.trim());
    return false;
  });
  if (titlePieces.length) working = titlePieces.join(' - ');

  const suffixPattern = new RegExp(
    `(?:\\s*[-–—|_()]\\s*)?((?:www\\s*\\.\\s*)?(?:${SONG_FOLDER_RAW_LABEL_PATTERN_SOURCE})(?:\\s*\\.\\s*(?:com(?:\\s*\\.\\s*(?:br|au))?|co\\s*\\.\\s*uk|net|org|store|ca))?)(?:\\s+\\d{2,4})?\\s*$`,
    'i'
  );
  const prefixPattern = new RegExp(
    `^\\s*((?:www\\s*\\.\\s*)?(?:${SONG_FOLDER_RAW_LABEL_PATTERN_SOURCE})(?:\\s*\\.\\s*(?:com(?:\\s*\\.\\s*(?:br|au))?|co\\s*\\.\\s*uk|net|org|store|ca))?)(?:\\s+\\d{2,4})?(?:\\s*[-–—|_:]\\s*)?`,
    'i'
  );
  let match = working.match(suffixPattern);
  if (match) {
    removedLabels.push(match[1]);
    working = working.slice(0, match.index).trim();
  }
  match = working.match(prefixPattern);
  if (match) {
    removedLabels.push(match[1]);
    working = working.slice(match[0].length).trim();
  }

  working = working.replace(/\s{2,}/g, ' ').replace(/^[-–—|_: ]+|[-–—|_: ]+$/g, '').trim();
  const name = working || rawName;
  return {
    name,
    rawName,
    changed: removedLabels.length > 0 || normalizeWords(name) !== normalizeWords(rawName),
    removedLabels: [...new Set(removedLabels.filter(Boolean))]
  };
}

function isSupportedAudioFile(filePath) {
  return SUPPORTED_AUDIO_EXTENSIONS.has(path.extname(String(filePath || '')).toLowerCase());
}

function stripSongName(fileStem, folderName) {
  const stem = normalizeWords(fileStem).replace(/^\s*\d{1,3}(?:\s+|(?=[a-z]))/, '').trim();
  const song = normalizeWords(folderName);
  if (!song) return stem;
  if (stem === song) return '';
  if (stem.endsWith(` ${song}`)) return stem.slice(0, -(song.length + 1)).trim();
  if (stem.startsWith(`${song} `)) return stem.slice(song.length + 1).trim();
  return stem;
}

function inferUnknownTrackCandidate(fileStem, folderName = '') {
  const normalizedName = stripSongName(fileStem, folderName)
    .replace(/^\s*\d{1,3}\s+/, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!normalizedName) return null;

  const acronyms = new Map([
    ['dj', 'DJ'],
    ['fx', 'FX'],
    ['midi', 'MIDI'],
    ['sfx', 'SFX']
  ]);
  const name = normalizedName
    .split(' ')
    .map((word) => acronyms.get(word) || `${word.charAt(0).toUpperCase()}${word.slice(1)}`)
    .join(' ');
  return { name, key: `custom:${normalizeTrackKey(normalizedName)}` };
}

function findVariant(normalizedName, rule) {
  const withoutBase = normalizedName
    .replace(rule.pattern, ' ')
    .replace(KEYBOARD_MODEL_REFERENCE_PATTERN, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const variants = [];
  const has = (pattern) => pattern.test(withoutBase);

  if (has(/\b(base|rhythm|ritmo)\b/)) variants.push('Base');
  if (has(/\b(solo)\b/)) variants.push('Solo');
  if (has(/\b(lead)\b/)) variants.push('Lead');
  if (has(/\b(clean|limpo)\b/)) variants.push('Clean');
  if (has(/\b(drive|dist|distorcao|distortion)\b/)) variants.push('Drive');
  if (has(/\b(midi)\b/)) variants.push('MIDI');

  const left = has(/\b(l|left|esq|esquerda)\b/);
  const right = has(/\b(r|right|dir|direita)\b/);
  if (left && !right) variants.push('L');
  if (right && !left) variants.push('R');

  const number = withoutBase.match(/(?:^|\s)([1-9]\d?)(?:\s|$)/);
  if (number) variants.push(number[1]);
  return [...new Set(variants)].join(' ');
}

function classifyCreateProjectTrack(filePath, folderName = '') {
  const fileName = path.basename(String(filePath || ''));
  const fileStem = path.basename(fileName, path.extname(fileName));
  const normalizedName = stripSongName(fileStem, folderName);
  const rule = CREATE_PROJECT_TRACK_RULES.find((item) => item.pattern.test(normalizedName));

  if (!rule) {
    const candidate = inferUnknownTrackCandidate(fileStem, folderName);
    return {
      name: 'Out',
      key: 'out',
      recognized: false,
      sourceName: fileStem,
      candidateName: candidate?.name || '',
      candidateKey: candidate?.key || ''
    };
  }

  // As pistas internas representam uma função única, independentemente de
  // complementos como "Base", "Voz" ou do nome usado pelo fornecedor.
  const internalTrack = rule.name === 'Click' || rule.name === 'Regência' || rule.name === 'Guia';
  const variant = internalTrack ? '' : findVariant(normalizedName, rule);
  const name = variant ? `${rule.name} ${variant}` : rule.name;
  return { name, key: normalizeTrackKey(name), recognized: true, sourceName: fileStem };
}

function inferSongNameFromAudioFiles(audioFiles, folderInference) {
  const candidates = new Map();
  for (const filePath of audioFiles) {
    const stem = path.basename(filePath, path.extname(filePath)).replace(/^\s*\d{1,3}\s*[.)_-]+\s*/, '').trim();
    const parts = stem.split(/\s*[_|]\s*|\s+[-–—]\s+/).map((part) => part.trim()).filter(Boolean);
    while (parts.length && /^\d{1,3}$/.test(parts[0])) parts.shift();
    if (parts.length < 2) continue;
    let candidate = '';
    for (let index = 0; index < parts.length - 1; index += 1) {
      const possibleTrack = parts.slice(0, index + 1).join(' ');
      if (!classifyCreateProjectTrack(possibleTrack).recognized) continue;
      candidate = parts.slice(index + 1).join(' - ').trim();
      break;
    }
    if (!candidate || candidate.length < 2) continue;
    const cleaned = inferSongNameFromFolder(candidate);
    const key = normalizeWords(cleaned.name);
    if (!key || SONG_FOLDER_LABEL_PATTERN.test(key)) continue;
    if (!candidates.has(key)) candidates.set(key, { ...cleaned, count: 0 });
    candidates.get(key).count += 1;
  }
  const best = [...candidates.values()].sort((a, b) => b.count - a.count || a.name.length - b.name.length)[0];
  const minimumAgreement = Math.min(2, audioFiles.length);
  if (!best || best.count < minimumAgreement) return { ...folderInference, source: folderInference.changed ? 'folder-cleaned' : 'folder' };

  const folderKey = normalizeWords(folderInference.name);
  const fileKey = normalizeWords(best.name);
  if (folderKey === fileKey || folderKey.includes(fileKey)) {
    return {
      ...best,
      rawName: folderInference.rawName,
      changed: fileKey !== normalizeWords(folderInference.rawName),
      removedLabels: [...new Set([...(folderInference.removedLabels || []), ...(best.removedLabels || [])])],
      source: fileKey === folderKey ? (folderInference.changed ? 'folder-cleaned' : 'folder') : 'audio-files'
    };
  }
  // Um título repetido em vários stems é um sinal forte, mas só substitui a
  // pasta automaticamente quando a pasta já contém uma etiqueta conhecida.
  if (folderInference.changed && best.count >= Math.ceil(audioFiles.length / 2)) {
    return {
      ...best,
      rawName: folderInference.rawName,
      changed: true,
      removedLabels: [...new Set([...(folderInference.removedLabels || []), ...(best.removedLabels || [])])],
      source: 'audio-files'
    };
  }
  return { ...folderInference, source: folderInference.changed ? 'folder-cleaned' : 'folder' };
}

function compareTracks(a, b) {
  const baseA = CREATE_PROJECT_TRACK_RULES.find((rule) => a.name === rule.name || a.name.startsWith(`${rule.name} `));
  const baseB = CREATE_PROJECT_TRACK_RULES.find((rule) => b.name === rule.name || b.name.startsWith(`${rule.name} `));
  const priorityA = a.name === 'Out' ? 10000 : (TRACK_PRIORITY.get(baseA?.name) ?? 9999);
  const priorityB = b.name === 'Out' ? 10000 : (TRACK_PRIORITY.get(baseB?.name) ?? 9999);
  return priorityA - priorityB || a.name.localeCompare(b.name, 'pt-BR', { numeric: true });
}

function getCreateProjectTrackBaseName(trackName) {
  const name = String(trackName || '');
  return CREATE_PROJECT_TRACK_RULES
    .filter((rule) => name === rule.name || name.startsWith(`${rule.name} `))
    .sort((left, right) => right.name.length - left.name.length)[0]?.name || 'Out';
}

function resolveCreateProjectTrackGroup(trackName) {
  const baseName = getCreateProjectTrackBaseName(trackName);
  return CREATE_PROJECT_TRACK_GROUPS.find((group) => group.trackNames?.has(baseName)) ||
    CREATE_PROJECT_TRACK_GROUPS[CREATE_PROJECT_TRACK_GROUPS.length - 1];
}

function reaperCustomColor({ red, green, blue }) {
  return 0x1000000 | red | (green << 8) | (blue << 16);
}

function cssColor({ red, green, blue }) {
  return `#${[red, green, blue].map((value) => value.toString(16).padStart(2, '0')).join('')}`;
}

function createProjectTrackGroups(tracks = []) {
  const palette = CREATE_PROJECT_GROUP_COLOR_PALETTE.map((color) => ({ ...color }));
  for (let index = palette.length - 1; index > 0; index -= 1) {
    const other = crypto.randomInt(index + 1);
    [palette[index], palette[other]] = [palette[other], palette[index]];
  }
  return CREATE_PROJECT_TRACK_GROUPS
    .map((definition) => {
      const groupTracks = tracks.filter((track) => resolveCreateProjectTrackGroup(track.name).key === definition.key);
      if (!groupTracks.length) return null;
      const color = palette.shift() || CREATE_PROJECT_GROUP_COLOR_PALETTE[0];
      return {
        key: definition.key,
        name: definition.name,
        color: reaperCustomColor(color),
        colorHex: cssColor(color),
        tracks: groupTracks
      };
    })
    .filter(Boolean);
}

async function mapWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  const runners = Array.from({ length: Math.min(Math.max(1, limit), items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(runners);
  return results;
}

function calculatePeakNormalizationGain(peakDb, targetDb = CREATE_PROJECT_INTERNAL_PEAK_DB) {
  const sourcePeak = Number(peakDb);
  const targetPeak = Number(targetDb);
  if (!Number.isFinite(sourcePeak) || !Number.isFinite(targetPeak)) return 1;
  return 10 ** ((targetPeak - sourcePeak) / 20);
}

async function auditCreateProjectFolders({ folderPaths = [], durationResolver, peakResolver, onProgress } = {}) {
  if (typeof durationResolver !== 'function') throw new Error('Leitor de duração de áudio indisponível.');
  const uniqueFolders = [...new Set(folderPaths.map((item) => path.resolve(String(item || ''))).filter(Boolean))];
  if (!uniqueFolders.length) throw new Error('Escolha pelo menos uma pasta de música.');

  const discoveredSongs = [];
  const emptyFolders = [];
  const skippedFiles = [];
  let discoveredAudioCount = 0;

  for (const folderPath of uniqueFolders) {
    const folderName = path.basename(folderPath);
    const folderSongName = inferSongNameFromFolder(folderName);
    let entries;
    try {
      entries = await fs.promises.readdir(folderPath, { withFileTypes: true });
    } catch (error) {
      emptyFolders.push({ folderPath, folderName, reason: `Não foi possível ler a pasta: ${error.message}` });
      continue;
    }
    const files = entries
      .filter((entry) => entry.isFile())
      .map((entry) => path.join(folderPath, entry.name));
    const audioFiles = files.filter(isSupportedAudioFile).sort((a, b) => path.basename(a).localeCompare(path.basename(b), 'pt-BR', { numeric: true }));
    files.filter((item) => !isSupportedAudioFile(item)).forEach((item) => {
      skippedFiles.push({ filePath: item, fileName: path.basename(item), folderName, reason: 'Formato não aceito' });
    });
    if (!audioFiles.length) {
      emptyFolders.push({ folderPath, folderName, reason: 'Nenhum arquivo WAV, AIFF ou MP3 encontrado diretamente nesta pasta.' });
      continue;
    }
    discoveredAudioCount += audioFiles.length;
    const inferredSongName = inferSongNameFromAudioFiles(audioFiles, folderSongName);
    discoveredSongs.push({ folderPath, folderName, inferredSongName, audioFiles });
  }

  let processed = 0;
  // Reserva o primeiro minuto do grid e mantém um minuto inteiro entre o fim
  // de uma música e o começo da próxima.
  let timelinePosition = CREATE_PROJECT_REGION_GAP_SECONDS;
  const songs = [];
  const trackMap = new Map();

  for (const discovered of discoveredSongs) {
    const measured = await mapWithConcurrency(discovered.audioFiles, 4, async (filePath) => {
      const classification = classifyCreateProjectTrack(filePath, discovered.inferredSongName.name);
      try {
        const resolvedDuration = await durationResolver(filePath);
        const duration = Number(resolvedDuration);
        if (!Number.isFinite(duration) || duration <= 0) throw new Error('duração inválida');
        const shouldNormalize = classification.name === 'Click' || classification.name === 'Regência';
        const peakDb = shouldNormalize && typeof peakResolver === 'function'
          ? await peakResolver(filePath)
          : null;
        const takeVolume = shouldNormalize && peakDb !== null
          ? calculatePeakNormalizationGain(peakDb)
          : 1;
        processed += 1;
        onProgress?.({ phase: 'audit', current: processed, total: discoveredAudioCount, percent: Math.round((processed / discoveredAudioCount) * 100), currentFile: path.basename(filePath) });
        return {
          filePath,
          fileName: path.basename(filePath),
          extension: path.extname(filePath).toLowerCase(),
          duration,
          trackName: classification.name,
          trackKey: classification.key,
          recognized: classification.recognized,
          candidateName: classification.candidateName || '',
          candidateKey: classification.candidateKey || '',
          // O primeiro valor de VOLPAN é o volume do item e permanece 1.
          // A normalização do REAPER é aplicada no ganho do take (3º valor).
          peakDb,
          normalizePeakDb: shouldNormalize && peakDb !== null
            ? CREATE_PROJECT_INTERNAL_PEAK_DB
            : null,
          takeVolume
        };
      } catch (error) {
        processed += 1;
        onProgress?.({ phase: 'audit', current: processed, total: discoveredAudioCount, percent: Math.round((processed / discoveredAudioCount) * 100), currentFile: path.basename(filePath) });
        skippedFiles.push({ filePath, fileName: path.basename(filePath), folderName: discovered.folderName, reason: `Áudio incompatível ou sem duração válida: ${error.message}` });
        return null;
      }
    });
    const files = measured.filter(Boolean);
    if (!files.length) {
      emptyFolders.push({ folderPath: discovered.folderPath, folderName: discovered.folderName, reason: 'Os arquivos encontrados não puderam ser lidos.' });
      continue;
    }

    if (songs.length > 0) timelinePosition += CREATE_PROJECT_REGION_GAP_SECONDS;
    const duration = Math.max(...files.map((item) => item.duration));
    const song = {
      name: discovered.inferredSongName.name,
      sourceFolderName: discovered.folderName,
      nameWasAdjusted: discovered.inferredSongName.changed,
      removedNameLabels: discovered.inferredSongName.removedLabels,
      nameSource: discovered.inferredSongName.source,
      folderPath: discovered.folderPath,
      start: timelinePosition,
      duration,
      end: timelinePosition + duration,
      files
    };
    songs.push(song);
    timelinePosition = song.end;
  }

  // Um nome desconhecido que se repete deixa de ser um caso isolado: a
  // auditoria cria uma pista própria e reserva Out somente para o que não
  // conseguiu identificar nem confirmar por recorrência.
  const recurringCandidates = new Map();
  for (const song of songs) {
    for (const file of song.files) {
      if (file.recognized || !file.candidateKey) continue;
      if (!recurringCandidates.has(file.candidateKey)) {
        recurringCandidates.set(file.candidateKey, { name: file.candidateName, count: 0 });
      }
      recurringCandidates.get(file.candidateKey).count += 1;
    }
  }
  for (const song of songs) {
    for (const file of song.files) {
      const candidate = recurringCandidates.get(file.candidateKey);
      if (!candidate || candidate.count < 2) continue;
      file.trackName = candidate.name;
      file.trackKey = file.candidateKey;
      file.recognized = true;
      file.inferredByRecurrence = true;
    }
  }

  // Dois arquivos da mesma música nunca podem ocupar a mesma pista e o
  // mesmo intervalo. Quando uma classificação se repete, abre outra pista
  // da mesma família em vez de sobrepor os itens no REAPER.
  for (const song of songs) {
    const reservedKeys = new Set(song.files.map((file) => file.trackKey));
    const usedKeys = new Set();
    for (const file of song.files) {
      if (!usedKeys.has(file.trackKey)) {
        usedKeys.add(file.trackKey);
        continue;
      }

      const baseName = file.trackName;
      let index = 2;
      let duplicateName = '';
      let duplicateKey = '';
      do {
        duplicateName = `${baseName} ${index}`;
        duplicateKey = file.trackKey.startsWith('custom:')
          ? `custom:${normalizeTrackKey(duplicateName)}`
          : normalizeTrackKey(duplicateName);
        index += 1;
      } while (reservedKeys.has(duplicateKey) || usedKeys.has(duplicateKey));

      file.trackName = duplicateName;
      file.trackKey = duplicateKey;
      file.separatedToPreventOverlap = true;
      reservedKeys.add(duplicateKey);
      usedKeys.add(duplicateKey);
    }
  }

  for (const song of songs) {
    for (const file of song.files) {
      if (!trackMap.has(file.trackKey)) {
        trackMap.set(file.trackKey, { name: file.trackName, key: file.trackKey, fileCount: 0, songNames: new Set(), unknownFileCount: 0 });
      }
      const track = trackMap.get(file.trackKey);
      track.fileCount += 1;
      track.songNames.add(song.name);
      if (!file.recognized) track.unknownFileCount += 1;
    }
  }

  const tracks = [...trackMap.values()]
    .map((track) => {
      const group = resolveCreateProjectTrackGroup(track.name);
      return { ...track, groupKey: group.key, groupName: group.name, songCount: track.songNames.size, songNames: [...track.songNames] };
    })
    .sort(compareTracks);
  const groups = createProjectTrackGroups(tracks);
  return {
    ok: true,
    folderPaths: uniqueFolders,
    totalFolders: uniqueFolders.length,
    validSongCount: songs.length,
    totalAudioFiles: discoveredAudioCount,
    totalIncludedFiles: songs.reduce((sum, song) => sum + song.files.length, 0),
    totalDuration: timelinePosition,
    tracks,
    groups,
    songs,
    emptyFolders,
    skippedFiles,
    unknownFileCount: tracks.reduce((sum, track) => sum + track.unknownFileCount, 0)
  };
}

function createGuid() {
  return `{${crypto.randomUUID().toUpperCase()}}`;
}

function quoteRpp(value) {
  return `"${String(value || '').replace(/"/g, "'")}"`;
}

function rppNumber(value) {
  const number = Number(value) || 0;
  return Number(number.toFixed(9)).toString();
}

function sanitizeCreateProjectMediaName(value, fallback = 'Audio') {
  const sanitized = String(value || '')
    .normalize('NFC')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/[. ]+$/g, '')
    .trim();
  return sanitized || fallback;
}

function createProjectMediaBaseName(song, songIndex, file) {
  const extension = path.extname(file.fileName || file.filePath).toLowerCase();
  const originalStem = path.basename(file.fileName || file.filePath, path.extname(file.fileName || file.filePath));
  const mediaIndex = Number.isInteger(song.mediaIndex) && song.mediaIndex >= 0 ? song.mediaIndex : songIndex;
  const songPart = sanitizeCreateProjectMediaName(song.name, `Musica ${mediaIndex + 1}`).slice(0, 52).trim();
  const filePart = sanitizeCreateProjectMediaName(originalStem, file.trackName || 'Audio').slice(0, 76).trim();
  return `${String(mediaIndex + 1).padStart(3, '0')} - ${songPart} - ${filePart}${extension}`;
}

async function createProjectMediaDestination(mediaDirectory, baseName, sourceStat, reservedNames) {
  const extension = path.extname(baseName);
  const stem = path.basename(baseName, extension);
  for (let suffix = 1; suffix < 10000; suffix += 1) {
    const fileName = suffix === 1 ? baseName : `${stem} (${suffix})${extension}`;
    const reservationKey = fileName.normalize('NFC').toLocaleLowerCase('en-US');
    if (reservedNames.has(reservationKey)) continue;
    const destinationPath = path.join(mediaDirectory, fileName);
    const destinationStat = await fs.promises.stat(destinationPath).catch((error) => {
      if (error?.code === 'ENOENT') return null;
      throw error;
    });
    if (!destinationStat) {
      reservedNames.add(reservationKey);
      return { destinationPath, fileName, reuse: false };
    }
    const sameCopy = destinationStat.isFile() &&
      destinationStat.size === sourceStat.size &&
      Math.abs(destinationStat.mtimeMs - sourceStat.mtimeMs) < 2000;
    if (sameCopy) {
      reservedNames.add(reservationKey);
      return { destinationPath, fileName, reuse: true };
    }
  }
  throw new Error(`Não foi possível criar um nome único para ${baseName}.`);
}

async function prepareCreateProjectMedia(audit, destinationPath, { onProgress } = {}) {
  if (!audit?.songs?.length) throw new Error('A auditoria não possui músicas válidas para copiar.');
  const projectDirectory = path.dirname(path.resolve(destinationPath));
  const mediaDirectory = path.join(projectDirectory, 'Media');
  await fs.promises.mkdir(mediaDirectory, { recursive: true });

  const reservedNames = new Set();
  const plans = [];
  for (let songIndex = 0; songIndex < audit.songs.length; songIndex += 1) {
    const song = audit.songs[songIndex];
    for (const file of song.files) {
      const sourcePath = path.resolve(file.filePath);
      const sourceStat = await fs.promises.stat(sourcePath);
      if (!sourceStat.isFile()) throw new Error(`O áudio não foi encontrado: ${file.fileName}`);
      const target = await createProjectMediaDestination(
        mediaDirectory,
        createProjectMediaBaseName(song, songIndex, file),
        sourceStat,
        reservedNames
      );
      plans.push({ songIndex, file, sourcePath, sourceStat, ...target });
    }
  }

  const createdFilePaths = [];
  const failures = [];
  let completed = 0;
  await mapWithConcurrency(plans, 3, async (plan) => {
    try {
      if (!plan.reuse) {
        await fs.promises.copyFile(plan.sourcePath, plan.destinationPath, fs.constants.COPYFILE_EXCL);
        await fs.promises.utimes(plan.destinationPath, plan.sourceStat.atime, plan.sourceStat.mtime).catch(() => {});
        createdFilePaths.push(plan.destinationPath);
      }
    } catch (error) {
      failures.push({ plan, error });
    } finally {
      completed += 1;
      onProgress?.({
        phase: 'copying',
        current: completed,
        total: plans.length,
        percent: plans.length ? Math.round((completed / plans.length) * 100) : 100,
        currentFile: plan.file.fileName
      });
    }
  });

  if (failures.length) {
    await Promise.allSettled(createdFilePaths.map((filePath) => fs.promises.unlink(filePath)));
    throw new Error(`Não foi possível copiar ${failures[0].plan.file.fileName} para a pasta Media: ${failures[0].error.message}`);
  }

  const planByFile = new Map(plans.map((plan) => [plan.file, plan]));
  const localizedAudit = {
    ...audit,
    songs: audit.songs.map((song) => ({
      ...song,
      files: song.files.map((file) => {
        const plan = planByFile.get(file);
        return {
          ...file,
          originalFilePath: file.filePath,
          projectFilePath: path.join('Media', plan.fileName)
        };
      })
    }))
  };

  return {
    audit: localizedAudit,
    mediaDirectory,
    createdFilePaths,
    copiedCount: plans.filter((plan) => !plan.reuse).length,
    reusedCount: plans.filter((plan) => plan.reuse).length
  };
}

async function writeCreateProjectFileExclusive(destinationPath, projectText) {
  try {
    await fs.promises.writeFile(destinationPath, projectText, {
      encoding: 'utf8',
      flag: 'wx'
    });
  } catch (error) {
    if (error?.code === 'EEXIST') {
      const conflict = new Error(CREATE_PROJECT_DESTINATION_EXISTS_MESSAGE);
      conflict.code = 'CREATE_PROJECT_DESTINATION_EXISTS';
      throw conflict;
    }
    throw error;
  }
}

function buildItemChunk(file, song, itemId) {
  const sourceType = file.extension === '.mp3' ? 'MP3' : 'WAVE';
  const sourcePath = file.projectFilePath || file.filePath;
  const fileLine = sourceType === 'MP3' ? `FILE ${quoteRpp(sourcePath)} 1` : `FILE ${quoteRpp(sourcePath)}`;
  return [
    '    <ITEM',
    `      POSITION ${rppNumber(song.start)}`,
    '      SNAPOFFS 0',
    `      LENGTH ${rppNumber(file.duration)}`,
    '      LOOP 0',
    '      ALLTAKES 0',
    '      FADEIN 1 0 0 1 0 0 0',
    '      FADEOUT 1 0 0 1 0 0 0',
    '      MUTE 0 0',
    '      SEL 0',
    `      IGUID ${createGuid()}`,
    `      IID ${itemId}`,
    `      NAME ${quoteRpp(file.fileName)}`,
    `      VOLPAN 1 0 ${rppNumber(file.takeVolume || 1)} -1`,
    '      SOFFS 0',
    '      PLAYRATE 1 1 0 -1 0 0.0025',
    '      CHANMODE 0',
    `      GUID ${createGuid()}`,
    `      <SOURCE ${sourceType}`,
    `        ${fileLine}`,
    '      >',
    '    >'
  ];
}

function buildFolderTrackChunk(group) {
  const trackGuid = createGuid();
  return [
    `  <TRACK ${trackGuid}`,
    `    NAME ${quoteRpp(group.name)}`,
    `    PEAKCOL ${group.color}`,
    '    BEAT -1',
    '    AUTOMODE 0',
    '    PANLAWFLAGS 3',
    '    VOLPAN 1 0 -1 -1 1',
    '    MUTESOLO 0 0 0',
    '    IPHASE 0',
    '    PLAYOFFS 0 1',
    '    ISBUS 1 1',
    '    BUSCOMP 0 0 0 0 0',
    '    SHOWINMIX 1 0.6667 0.5 1 0.5 0 0 0',
    '    FREEMODE 0',
    '    SEL 0',
    '    REC 0 0 1 0 0 0 0 0',
    '    VU 2',
    '    TRACKHEIGHT 0 0 0 0 0 0 0',
    '    INQ 0 0 0 0.5 100 0 0 100',
    '    NCHAN 2',
    '    FX 1',
    `    TRACKID ${trackGuid}`,
    '    PERF 0',
    '    MIDIOUT -1',
    '    MAINSEND 1 0',
    '  >'
  ];
}

function buildTrackChunk(track, songs, itemCounter, color, closesFolder = false) {
  const trackGuid = createGuid();
  const lines = [
    `  <TRACK ${trackGuid}`,
    `    NAME ${quoteRpp(track.name)}`,
    `    PEAKCOL ${color}`,
    '    BEAT -1',
    '    AUTOMODE 0',
    '    PANLAWFLAGS 3',
    '    VOLPAN 1 0 -1 -1 1',
    '    MUTESOLO 0 0 0',
    '    IPHASE 0',
    '    PLAYOFFS 0 1',
    closesFolder ? '    ISBUS 2 -1' : '    ISBUS 0 0',
    '    BUSCOMP 0 0 0 0 0',
    '    SHOWINMIX 1 0.6667 0.5 1 0.5 0 0 0',
    '    FREEMODE 0',
    '    SEL 0',
    '    REC 0 0 1 0 0 0 0 0',
    '    VU 2',
    '    TRACKHEIGHT 0 0 0 0 0 0 0',
    '    INQ 0 0 0 0.5 100 0 0 100',
    '    NCHAN 2',
    '    FX 1',
    `    TRACKID ${trackGuid}`,
    '    PERF 0',
    '    MIDIOUT -1',
    '    MAINSEND 1 0'
  ];
  for (const song of songs) {
    for (const file of song.files.filter((item) => item.trackKey === track.key)) {
      itemCounter.value += 1;
      lines.push(...buildItemChunk(file, song, itemCounter.value));
    }
  }
  lines.push('  >');
  return lines;
}

function buildCreateProjectRpp(audit, { platform = process.platform } = {}) {
  if (!audit?.songs?.length || !audit?.tracks?.length) throw new Error('A auditoria não possui músicas válidas para criar o projeto.');
  const platformName = platform === 'darwin' ? 'OSX64' : 'win64';
  const lines = [
    `<REAPER_PROJECT 0.1 ${quoteRpp(`7.0/${platformName}`)} ${Math.floor(Date.now() / 1000)}`,
    '  RIPPLE 0',
    '  GROUPOVERRIDE 0 0 0',
    '  AUTOXFADE 1',
    '  ENVATTACH 1',
    '  POOLEDENVATTACH 0',
    '  MIXERUIFLAGS 11 48',
    '  PEAKGAIN 1',
    '  FEEDBACK 0',
    '  PANLAW 1',
    '  PROJOFFS 0 0 0',
    '  MAXPROJLEN 0 0',
    '  GRID 3199 8 1 8 1 0 0 0',
    '  TIMEMODE 1 5 -1 30 0 0 -1',
    '  VIDEO_CONFIG 0 0 256',
    '  PANMODE 3',
    '  CURSOR 0',
    '  ZOOM 100 0 0',
    '  VZOOMEX 6 0',
    '  USE_REC_CFG 0',
    '  RECMODE 1',
    '  LOOP 0',
    '  LOOPGRAN 0 4',
    '  RECORD_PATH "Media" ""',
    '  RENDER_FILE ""',
    '  RENDER_PATTERN ""',
    '  RENDER_FMT 0 2 0',
    '  RENDER_1X 0',
    '  RENDER_RANGE 1 0 0 18 1000',
    '  RENDER_RESAMPLE 3 0 1',
    '  RENDER_ADDTOPROJ 0',
    '  RENDER_STEMS 0',
    '  RENDER_DITHER 0',
    '  TIMELOCKMODE 1',
    '  TEMPOENVLOCKMODE 1',
    '  ITEMMIX 1',
    '  DEFPITCHMODE 589824 0',
    '  TAKELANE 1',
    '  SAMPLERATE 48000 0 0',
    '  <RECORD_CFG',
    '  >',
    '  <APPLYFX_CFG',
    '  >',
    '  <RENDER_CFG',
    '  >',
    '  LOCK 1',
    '  TEMPO 120 4 4',
    '  PLAYRATE 1 0 0.25 4',
    '  SELECTION 0 0',
    '  SELECTION2 0 0',
    '  MASTERAUTOMODE 0',
    '  MASTERTRACKHEIGHT 0 0',
    '  MASTERPEAKCOL 16576',
    '  MASTERMUTESOLO 0',
    '  MASTERTRACKVIEW 0 0.6667 0.5 0.5 -1 -1 -1 0 0 0 -1 -1 0',
    '  MASTERHWOUT 0 0 1 0 0 0 0 -1'
  ];

  audit.songs.forEach((song, index) => {
    const regionId = index + 1;
    lines.push(`  MARKER ${regionId} ${rppNumber(song.start)} ${quoteRpp(song.name)} 1 0 1 R ${createGuid()} 0 1`);
    lines.push(`  MARKER ${regionId} ${rppNumber(song.end)} "" 1`);
  });
  const itemCounter = { value: 0 };
  const groups = Array.isArray(audit.groups) && audit.groups.length
    ? audit.groups
    : createProjectTrackGroups(audit.tracks);
  for (const group of groups) {
    lines.push(...buildFolderTrackChunk(group));
    group.tracks.forEach((track, index) => {
      lines.push(...buildTrackChunk(track, audit.songs, itemCounter, group.color, index === group.tracks.length - 1));
    });
  }
  lines.push('>');
  return `${lines.join('\n')}\n`;
}

function readExtended80(buffer, offset) {
  const exponent = buffer.readUInt16BE(offset);
  const sign = (exponent & 0x8000) ? -1 : 1;
  const exp = exponent & 0x7fff;
  const high = buffer.readUInt32BE(offset + 2);
  const low = buffer.readUInt32BE(offset + 6);
  if (exp === 0 && high === 0 && low === 0) return 0;
  const mantissa = high * 2 ** 32 + low;
  return sign * mantissa * 2 ** (exp - 16383 - 63);
}

async function readPcmAudioDuration(filePath) {
  const handle = await fs.promises.open(filePath, 'r');
  try {
    const stat = await handle.stat();
    const headerSize = Math.min(stat.size, 1024 * 1024);
    const buffer = Buffer.alloc(headerSize);
    await handle.read(buffer, 0, headerSize, 0);
    const signature = buffer.toString('ascii', 0, 4);

    if (signature === 'RIFF' && buffer.toString('ascii', 8, 12) === 'WAVE') {
      let offset = 12;
      let byteRate = 0;
      let dataSize = 0;
      while (offset + 8 <= buffer.length) {
        const chunkId = buffer.toString('ascii', offset, offset + 4);
        const chunkSize = buffer.readUInt32LE(offset + 4);
        if (chunkId === 'fmt ' && offset + 20 <= buffer.length) byteRate = buffer.readUInt32LE(offset + 16);
        if (chunkId === 'data') {
          // Nunca permita que um cabeçalho RIFF incorreto faça o item passar
          // do fim físico da mídia.
          dataSize = Math.min(chunkSize, Math.max(0, stat.size - (offset + 8)));
          break;
        }
        offset += 8 + chunkSize + (chunkSize % 2);
      }
      if (byteRate > 0 && dataSize > 0) return dataSize / byteRate;
    }

    if ((signature === 'FORM') && ['AIFF', 'AIFC'].includes(buffer.toString('ascii', 8, 12))) {
      let offset = 12;
      let frames = 0;
      let sampleRate = 0;
      while (offset + 8 <= buffer.length) {
        const chunkId = buffer.toString('ascii', offset, offset + 4);
        const chunkSize = buffer.readUInt32BE(offset + 4);
        if (chunkId === 'COMM' && offset + 26 <= buffer.length) {
          frames = buffer.readUInt32BE(offset + 10);
          sampleRate = readExtended80(buffer, offset + 16);
          break;
        }
        offset += 8 + chunkSize + (chunkSize % 2);
      }
      if (frames > 0 && sampleRate > 0) return frames / sampleRate;
    }
    return 0;
  } finally {
    await handle.close();
  }
}

const MPEG_BITRATES = {
  '1-1': [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  '1-2': [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  '1-3': [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  '2-1': [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  '2-2': [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  '2-3': [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
};

function parseMp3FrameHeader(buffer, offset) {
  if (offset + 4 > buffer.length) return null;
  const header = buffer.readUInt32BE(offset);
  if (((header & 0xffe00000) >>> 0) !== 0xffe00000) return null;
  const versionBits = (header >>> 19) & 0x3;
  const layerBits = (header >>> 17) & 0x3;
  const bitrateIndex = (header >>> 12) & 0xf;
  const sampleRateIndex = (header >>> 10) & 0x3;
  if (versionBits === 1 || layerBits === 0 || bitrateIndex === 0 || bitrateIndex === 15 || sampleRateIndex === 3) return null;

  const version = versionBits === 3 ? 1 : (versionBits === 2 ? 2 : 2.5);
  const layer = 4 - layerBits;
  const bitrateVersion = version === 1 ? 1 : 2;
  const bitrate = MPEG_BITRATES[`${bitrateVersion}-${layer}`]?.[bitrateIndex] || 0;
  const baseSampleRates = [44100, 48000, 32000];
  const sampleRate = baseSampleRates[sampleRateIndex] / (version === 1 ? 1 : version === 2 ? 2 : 4);
  const padding = (header >>> 9) & 1;
  const channelMode = (header >>> 6) & 0x3;
  const hasCrc = ((header >>> 16) & 1) === 0;
  if (!bitrate || !sampleRate) return null;

  const frameLength = layer === 1
    ? Math.floor((12 * bitrate * 1000) / sampleRate + padding) * 4
    : Math.floor(((layer === 3 && version !== 1) ? 72 : 144) * bitrate * 1000 / sampleRate + padding);
  const samplesPerFrame = layer === 1 ? 384 : (layer === 2 || version === 1 ? 1152 : 576);
  if (frameLength < 24) return null;
  return { version, layer, bitrate, sampleRate, padding, channelMode, hasCrc, frameLength, samplesPerFrame };
}

function readSyncSafeInteger(buffer, offset) {
  return ((buffer[offset] & 0x7f) << 21) |
    ((buffer[offset + 1] & 0x7f) << 14) |
    ((buffer[offset + 2] & 0x7f) << 7) |
    (buffer[offset + 3] & 0x7f);
}

function findFirstMp3Frame(buffer, startOffset = 0) {
  for (let offset = Math.max(0, startOffset); offset + 8 < buffer.length; offset += 1) {
    const frame = parseMp3FrameHeader(buffer, offset);
    if (!frame) continue;
    const nextOffset = offset + frame.frameLength;
    if (nextOffset + 4 <= buffer.length && parseMp3FrameHeader(buffer, nextOffset)) {
      return { offset, frame };
    }
  }
  return null;
}

function getMp3FrameCountFromVbrHeader(buffer, frameOffset, frame) {
  if (frame.layer !== 3) return 0;
  const sideInfoSize = frame.version === 1
    ? (frame.channelMode === 3 ? 17 : 32)
    : (frame.channelMode === 3 ? 9 : 17);
  const xingOffset = frameOffset + 4 + (frame.hasCrc ? 2 : 0) + sideInfoSize;
  const xingId = buffer.toString('ascii', xingOffset, xingOffset + 4);
  if ((xingId === 'Xing' || xingId === 'Info') && xingOffset + 12 <= buffer.length) {
    const flags = buffer.readUInt32BE(xingOffset + 4);
    if (flags & 1) return buffer.readUInt32BE(xingOffset + 8);
  }
  const vbriOffset = frameOffset + 4 + 32;
  if (buffer.toString('ascii', vbriOffset, vbriOffset + 4) === 'VBRI' && vbriOffset + 18 <= buffer.length) {
    return buffer.readUInt32BE(vbriOffset + 14);
  }
  return 0;
}

async function readMp3AudioDuration(filePath) {
  const handle = await fs.promises.open(filePath, 'r');
  try {
    const stat = await handle.stat();
    if (stat.size < 8) return 0;
    const bufferSize = Math.min(stat.size, 1024 * 1024);
    const buffer = Buffer.alloc(bufferSize);
    await handle.read(buffer, 0, bufferSize, 0);
    let audioStart = 0;
    if (buffer.toString('ascii', 0, 3) === 'ID3' && buffer.length >= 10) {
      audioStart = 10 + readSyncSafeInteger(buffer, 6) + ((buffer[5] & 0x10) ? 10 : 0);
    }
    const firstFrame = findFirstMp3Frame(buffer, audioStart);
    if (!firstFrame) return 0;
    const frameCount = getMp3FrameCountFromVbrHeader(buffer, firstFrame.offset, firstFrame.frame);
    if (frameCount > 0) return frameCount * firstFrame.frame.samplesPerFrame / firstFrame.frame.sampleRate;

    let audioEnd = stat.size;
    if (stat.size >= 128) {
      const tail = Buffer.alloc(128);
      await handle.read(tail, 0, 128, stat.size - 128);
      if (tail.toString('ascii', 0, 3) === 'TAG') audioEnd -= 128;
    }
    const audioBytes = Math.max(0, audioEnd - firstFrame.offset);
    return audioBytes * 8 / (firstFrame.frame.bitrate * 1000);
  } finally {
    await handle.close();
  }
}

module.exports = {
  CREATE_PROJECT_DESTINATION_EXISTS_MESSAGE,
  CREATE_PROJECT_INTERNAL_PEAK_DB,
  CREATE_PROJECT_REGION_GAP_SECONDS,
  CREATE_PROJECT_TRACK_GROUPS,
  SUPPORTED_AUDIO_EXTENSIONS,
  auditCreateProjectFolders,
  buildCreateProjectRpp,
  buildFolderTrackChunk,
  buildItemChunk,
  buildTrackChunk,
  calculatePeakNormalizationGain,
  classifyCreateProjectTrack,
  containsCreateProjectTrackName,
  compareTracks,
  createGuid,
  createProjectTrackGroups,
  inferSongNameFromFolder,
  isSupportedAudioFile,
  isCreateProjectSourceLabel,
  isCreateProjectTrackLabel,
  normalizeTrackKey,
  prepareCreateProjectMedia,
  quoteRpp,
  rppNumber,
  resolveCreateProjectTrackGroup,
  readMp3AudioDuration,
  readPcmAudioDuration,
  writeCreateProjectFileExclusive
};
