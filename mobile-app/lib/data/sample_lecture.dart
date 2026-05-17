// A built-in lecture so the app demos end-to-end without needing a live Pi
// to record audio. Installed once on first launch by [BundleStore].

const String kSampleLectureClassId = 'sample_cell_biology';
const String kSampleLectureTitle = 'Intro to Cell Biology';
const String kSampleLectureTeacher = 'EchoLang Sample';

const String kSampleLectureTranscript = '''
Welcome back, everyone. Today we are starting our unit on cell biology, the
study of the smallest unit of life that can still be called alive. Every
living thing you have ever seen — every tree, every animal, every person — is
either a single cell or a colony of cells working together. By the end of this
lecture you should be able to state the three tenets of cell theory, explain
the major difference between prokaryotic and eukaryotic cells, and describe
the main jobs of the organelles we will be discussing.

Let us start with cell theory. Cell theory has three core claims. First, all
living organisms are made of one or more cells. Second, the cell is the
basic unit of structure and function in living things. Third, all cells come
from pre-existing cells. That third point was the surprising one
historically. Before the 1850s, many scientists believed cells could appear
spontaneously from non-living matter. Rudolf Virchow's famous statement
"omnis cellula e cellula" — every cell from a cell — settled that debate and
became the third tenet of cell theory.

Cells fall into two broad categories: prokaryotes and eukaryotes.
Prokaryotic cells, which include bacteria and archaea, are usually smaller,
typically one to ten micrometers across. They have no membrane-bound nucleus.
Their DNA sits in a region of the cytoplasm called the nucleoid, and they
generally lack the internal compartments — the organelles — that we will
spend most of our time on today. Eukaryotic cells, in contrast, are larger,
typically ten to one hundred micrometers, and they contain a true nucleus
plus a whole collection of membrane-bound organelles. Plant cells, animal
cells, fungal cells, and the cells of every protist you can think of are all
eukaryotic.

The boundary of every cell, prokaryote or eukaryote, is the plasma membrane.
The plasma membrane is a phospholipid bilayer. Each phospholipid has a
hydrophilic head, which is attracted to water, and two hydrophobic fatty
acid tails, which avoid water. In an aqueous environment those molecules
spontaneously arrange themselves into a bilayer, with the heads facing the
water on both sides and the tails tucked into the interior. Embedded in this
bilayer are proteins that act as channels, pumps, receptors, and identity
markers. The plasma membrane is selectively permeable: small nonpolar
molecules like oxygen and carbon dioxide pass through freely, while ions and
larger polar molecules need a protein-mediated route.

Inside the membrane is the cytoplasm — a gel-like fluid that holds the
organelles in place and is criss-crossed by the cytoskeleton, a network of
protein fibers that gives the cell its shape and lets it move materials
around internally.

In eukaryotic cells, the nucleus is the largest and most prominent organelle.
The nucleus is enclosed by a double membrane called the nuclear envelope,
which is pierced by nuclear pores that regulate the traffic of molecules in
and out. Inside the nucleus you find the cell's DNA, organized into
chromosomes, plus a dense region called the nucleolus where ribosomes are
assembled.

Speaking of ribosomes — ribosomes are the molecular machines that translate
messenger RNA into protein. They can float free in the cytoplasm or be bound
to a membrane network called the rough endoplasmic reticulum. The rough ER
is studded with ribosomes and produces proteins destined for export from the
cell or for insertion into the membrane. Right next to it is the smooth
endoplasmic reticulum, which has no ribosomes and instead handles lipid
synthesis and detoxification of harmful substances.

Proteins and lipids from the ER are then shipped to the Golgi apparatus, a
stack of flattened membrane sacs that act like the cell's post office. The
Golgi modifies, sorts, and packages those molecules into vesicles which then
fuse with the target membrane — often the plasma membrane, so the cell can
release its contents to the outside.

Mitochondria are the energy organelles. They have their own double membrane;
the inner membrane is heavily folded into structures called cristae, which
provide a large surface area for the protein complexes of the electron
transport chain. Mitochondria use oxygen and the breakdown products of
glucose to produce ATP, the cell's main energy currency. Plant cells also
contain chloroplasts, which run the reverse process — capturing light energy
to convert carbon dioxide and water into glucose, the topic of our next
lecture on photosynthesis. Both mitochondria and chloroplasts carry their
own small loop of DNA, which is one of the strongest pieces of evidence for
the endosymbiotic theory: the idea that these organelles were once
free-living bacteria engulfed by a larger cell about 1.5 billion years ago.

Plant cells have two more structures animal cells do not. The cell wall, made
mostly of cellulose, lies outside the plasma membrane and gives plant cells
their rigid box-like shape. And the central vacuole is a large
fluid-filled sac that maintains the cell's internal water pressure, called
turgor, which is what keeps a non-woody plant standing up. When you forget
to water a houseplant and it wilts, you are watching central vacuoles lose
turgor in real time.

That is your overview. Next time we will zoom in on the plasma membrane and
talk about how molecules actually cross it — diffusion, osmosis, and the
active transport pumps that let cells maintain concentration gradients
against their will. Read chapter four before then, and please attempt the
practice problems at the end. Good luck, see you Thursday.
''';
