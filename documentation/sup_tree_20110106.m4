define(main_setup, `
/* General coloration and font setup */
rankdir=LR;
node [fontname="URW Gothic L",fontsize=12,shape=plaintext,labelfontname=Helvetica];
labeljust = l;
labelloc = t;

fontsize = 24;
fontname="URW Gothic L";

label = "Etorrent Supervisor Tree:";
')

define(sup_s, `$1 [label="$1", shape=box, color=red];')
define(sup_11, `$1 [label="$1", shape=box, color=blue];')
define(sup_1a, `$1 [label="$1", shape=box, color=green];')

define(suggest_link, `$1 -> $2 [style=dashed,color=lightgrey];')
define(link, `$1 -> $2')
digraph etorrent_sup {

main_setup

	subgraph cluster_legend {
	  label="Legend";
	  color="deepskyblue4";
	  fontsize=14;
		{ rank=same;
		  sup_s(`simple_one_for_one')
		  sup_11(`one_for_one')
		  sup_1a(`one_for_all')
		}
	}

	/* Top level */
	sup_1a(`etorrent_sup')

	/* Torrent Global */
	{ rank=same;
	  sup_1a(`listen_sup')
	  sup_11(`dht')
	  sup_11(`dirwatcher_sup')
	  sup_11(`torrent_pool')
	  sup_1a(`udp_tracker_sup')
        }

	link(`etorrent_sup', `listen_sup')
	link(`etorrent_sup', `dht')
	link(`etorrent_sup', `dirwatcher_sup')
	link(`etorrent_sup', `torrent_pool')
	link(`etorrent_sup', `udp_tracker_sup')

	/* UDP Tracking */
	sup_s(`udp_pool')
	sup_11(`udp_proto_sup')

	link(`udp_tracker_sup', `udp_pool')
	link(`udp_tracker_sup', `udp_proto_sup')

	/* Torrent Pool */
	subgraph cluster_torrent {
          label="Torrent";
	  color="deepskyblue4";
	  fontsize=14;

	  sup_1a(`torrent_sup')

	  { rank=same;
	    sup_11(`io_sup')
	    sup_s(`peer_pool')
          }

	  link(`torrent_sup', `io_sup')
	  link(`torrent_sup', `peer_pool')

 	  sup_1a(`peer_pool')
	  sup_1a(`file_io_sup')

	  suggest_link(`peer_pool', `peer_sup')
	  suggest_link(`io_sup', `file_io_sup')
	}

	suggest_link(`torrent_pool', `torrent_sup')
}
