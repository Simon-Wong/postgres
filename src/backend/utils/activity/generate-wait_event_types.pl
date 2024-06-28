#!/usr/bin/perl
#----------------------------------------------------------------------
#
# Generate wait events support files from wait_event_names.txt:
# - wait_event_types.h (if --code is passed)
# - pgstat_wait_event.c (if --code is passed)
# - wait_event_funcs_data.c (if --code is passed)
# - wait_event_types.sgml (if --docs is passed)
#
# Portions Copyright (c) 1996-2024, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
# src/backend/utils/activity/generate-wait_event_types.pl
#
#----------------------------------------------------------------------

use strict;
use warnings FATAL => 'all';
use Getopt::Long;

my $output_path = '.';
my $gen_docs = 0;
my $gen_code = 0;

my $continue = "\n";
my %hashwe;

GetOptions(
	'outdir:s' => \$output_path,
	'docs' => \$gen_docs,
	'code' => \$gen_code) || usage();

die "Needs to specify --docs or --code"
  if (!$gen_docs && !$gen_code);

die "Not possible to specify --docs and --code simultaneously"
  if ($gen_docs && $gen_code);

open my $wait_event_names, '<', $ARGV[0] or die;

my @abi_compatibility_lines;
my @lines;
my $abi_compatibility = 0;
my $section_name;
my $note;
my $note_name;

# Remove comments and empty lines and add waitclassname based on the section
while (<$wait_event_names>)
{
	chomp;

	# Skip comments
	next if /^#/;

	# Skip empty lines
	next if /^\s*$/;

	# Get waitclassname based on the section
	if (/^Section: ClassName(.*)/)
	{
		$section_name = $_;
		$section_name =~ s/^.*- //;
		$abi_compatibility = 0;
		next;
	}

	# ABI_compatibility region, preserving ABI compatibility of the code
	# generated.  Any wait events listed in this part of the file will
	# not be sorted during the code generation.
	if (/^ABI_compatibility:$/)
	{
		$abi_compatibility = 1;
		next;
	}

	if ($gen_code && $abi_compatibility)
	{
		push(@abi_compatibility_lines, $section_name . "\t" . $_);
	}
	else
	{
		push(@lines, $section_name . "\t" . $_);
	}
}

# Sort the lines based on the second column.
# uc() is being used to force the comparison to be case-insensitive.
my @lines_sorted =
  sort { uc((split(/\t/, $a))[1]) cmp uc((split(/\t/, $b))[1]) } @lines;

# If we are generating code, concat @lines_sorted and then
# @abi_compatibility_lines.
if ($gen_code)
{
	push(@lines_sorted, @abi_compatibility_lines);
}

# Read the sorted lines and populate the hash table
foreach my $line (@lines_sorted)
{
	die "unable to parse wait_event_names.txt for line $line\n"
	  unless $line =~ /^(\w+)\t+(\w+)\t+("\w.*\.")$/;

	(my $waitclassname, my $waiteventname, my $waitevendocsentence) =
	  split(/\t/, $line);

	# Generate the element name for the enums based on the
	# description.  The C symbols are prefixed with "WAIT_EVENT_".
	my $waiteventenumname = "WAIT_EVENT_$waiteventname";

	# Build the descriptions.  These are in camel-case.
	# LWLock and Lock classes do not need any modifications.
	my $waiteventdescription = '';
	if (   $waitclassname eq 'WaitEventLWLock'
		|| $waitclassname eq 'WaitEventLock')
	{
		$waiteventdescription = $waiteventname;
	}
	else
	{
		my @waiteventparts = split("_", $waiteventname);
		foreach my $waiteventpart (@waiteventparts)
		{
			$waiteventdescription .= substr($waiteventpart, 0, 1)
			  . lc(substr($waiteventpart, 1, length($waiteventpart)));
		}
	}

	# Store the event into the list for each class.
	my @waiteventlist =
	  [ $waiteventenumname, $waiteventdescription, $waitevendocsentence ];
	push(@{ $hashwe{$waitclassname} }, @waiteventlist);
}


# Generate the .c and .h files.
if ($gen_code)
{
	# Include PID in suffix in case parallel make runs this script
	# multiple times.
	my $htmp = "$output_path/wait_event_types.h.tmp$$";
	my $ctmp = "$output_path/pgstat_wait_event.c.tmp$$";
	my $wctmp = "$output_path/wait_event_funcs_data.c.tmp$$";
	open my $h, '>', $htmp or die "Could not open $htmp: $!";
	open my $c, '>', $ctmp or die "Could not open $ctmp: $!";
	open my $wc, '>', $wctmp or die "Could not open $wctmp: $!";

	my $header_comment =
	  '/*-------------------------------------------------------------------------
 *
 * %s
 *    Generated wait events infrastructure code
 *
 * Portions Copyright (c) 1996-2024, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *  ******************************
 *  *** DO NOT EDIT THIS FILE! ***
 *  ******************************
 *
 *  It has been GENERATED by src/backend/utils/activity/generate-wait_event_types.pl
 *
 *-------------------------------------------------------------------------
 */

';

	printf $h $header_comment, 'wait_event_types.h';
	printf $h "#ifndef WAIT_EVENT_TYPES_H\n";
	printf $h "#define WAIT_EVENT_TYPES_H\n\n";
	printf $h "#include \"utils/wait_event.h\"\n\n";

	printf $c $header_comment, 'pgstat_wait_event.c';

	printf $wc $header_comment, 'wait_event_funcs_data.c';

	# Generate the pgstat_wait_event.c and wait_event_types.h files
	# uc() is being used to force the comparison to be case-insensitive.
	foreach my $waitclass (sort { uc($a) cmp uc($b) } keys %hashwe)
	{
		# Don't generate the pgstat_wait_event.c and wait_event_types.h files
		# for types handled independently.
		next
		  if ( $waitclass eq 'WaitEventExtension'
			|| $waitclass eq 'WaitEventInjectionPoint'
			|| $waitclass eq 'WaitEventLWLock'
			|| $waitclass eq 'WaitEventLock');

		my $last = $waitclass;
		$last =~ s/^WaitEvent//;
		my $lastuc = uc $last;
		my $lastlc = lc $last;
		my $firstpass = 1;
		my $pg_wait_class;

		printf $c
		  "static const char *\npgstat_get_wait_$lastlc($waitclass w)\n{\n";
		printf $c "\tconst char *event_name = \"unknown wait event\";\n\n";
		printf $c "\tswitch (w)\n\t{\n";

		foreach my $wev (@{ $hashwe{$waitclass} })
		{
			if ($firstpass)
			{
				printf $h "typedef enum\n{\n";
				$pg_wait_class = "PG_WAIT_" . $lastuc;
				printf $h "\t%s = %s", $wev->[0], $pg_wait_class;
				$continue = ",\n";
			}
			else
			{
				printf $h "%s\t%s", $continue, $wev->[0];
				$continue = ",\n";
			}
			$firstpass = 0;

			printf $c "\t\t case %s:\n", $wev->[0];
			# Apply quotes to the wait event name string.
			printf $c "\t\t\t event_name = \"%s\";\n\t\t\t break;\n",
			  $wev->[1];
		}

		printf $h "\n} $waitclass;\n\n";

		printf $c
		  "\t\t\t /* no default case, so that compiler will warn */\n";
		printf $c "\t}\n\n";
		printf $c "\treturn event_name;\n";
		printf $c "}\n\n";
	}

	# Generate wait_event_funcs_data.c, building the contents of a static
	# C structure holding all the information about the wait events.
	# uc() is being used to force the comparison to be case-insensitive,
	# even though it is not required here.
	foreach my $waitclass (sort { uc($a) cmp uc($b) } keys %hashwe)
	{
		my $last = $waitclass;
		$last =~ s/^WaitEvent//;

		foreach my $wev (@{ $hashwe{$waitclass} })
		{
			my $new_desc = substr $wev->[2], 1, -2;
			# Escape single quotes.
			$new_desc =~ s/'/\\'/g;

			# Replace the "quote" markups by real ones.
			$new_desc =~ s/<quote>(.*?)<\/quote>/\\"$1\\"/g;

			# Remove SGML markups.
			$new_desc =~ s/<.*?>(.*?)<.*?>/$1/g;

			# Tweak contents about links <xref linkend="text"/>
			# on GUCs,
			while (my ($capture) =
				$new_desc =~ m/<xref linkend="guc-(.*?)"\/>/g)
			{
				$capture =~ s/-/_/g;
				$new_desc =~ s/<xref linkend="guc-.*?"\/>/$capture/g;
			}
			# Then remove any reference to
			# "see <xref linkend="text"/>".
			$new_desc =~ s/; see.*$//;

			# Build one element of the C structure holding the
			# wait event info, as of (type, name, description).
			printf $wc "\t{\"%s\", \"%s\", \"%s\"},\n", $last, $wev->[1],
			  $new_desc;
		}
	}

	printf $h "#endif                          /* WAIT_EVENT_TYPES_H */\n";
	close $h;
	close $c;
	close $wc;

	rename($htmp, "$output_path/wait_event_types.h")
	  || die "rename: $htmp to $output_path/wait_event_types.h: $!";
	rename($ctmp, "$output_path/pgstat_wait_event.c")
	  || die "rename: $ctmp to $output_path/pgstat_wait_event.c: $!";
	rename($wctmp, "$output_path/wait_event_funcs_data.c")
	  || die "rename: $wctmp to $output_path/wait_event_funcs_data.c: $!";
}
# Generate the .sgml file.
elsif ($gen_docs)
{
	# Include PID in suffix in case parallel make runs this multiple times.
	my $stmp = "$output_path/wait_event_names.s.tmp$$";
	open my $s, '>', $stmp or die "Could not open $stmp: $!";

	# uc() is being used to force the comparison to be case-insensitive.
	foreach my $waitclass (sort { uc($a) cmp uc($b) } keys %hashwe)
	{
		my $last = $waitclass;
		$last =~ s/^WaitEvent//;
		my $lastlc = lc $last;

		printf $s "  <table id=\"wait-event-%s-table\">\n", $lastlc;
		printf $s
		  "   <title>Wait Events of Type <literal>%s</literal></title>\n",
		  ucfirst($lastlc);
		printf $s "   <tgroup cols=\"2\">\n";
		printf $s "    <thead>\n";
		printf $s "     <row>\n";
		printf $s
		  "      <entry><literal>$last</literal> Wait Event</entry>\n";
		printf $s "      <entry>Description</entry>\n";
		printf $s "     </row>\n";
		printf $s "    </thead>\n\n";
		printf $s "    <tbody>\n";

		foreach my $wev (@{ $hashwe{$waitclass} })
		{
			printf $s "     <row>\n";
			printf $s "      <entry><literal>%s</literal></entry>\n",
			  $wev->[1];
			printf $s "      <entry>%s</entry>\n", substr $wev->[2], 1, -1;
			printf $s "     </row>\n";
		}

		printf $s "    </tbody>\n";
		printf $s "   </tgroup>\n";
		printf $s "  </table>\n\n";
	}

	close $s;

	rename($stmp, "$output_path/wait_event_types.sgml")
	  || die "rename: $stmp to $output_path/wait_event_types.sgml: $!";
}

close $wait_event_names;

sub usage
{
	die <<EOM;
Usage: perl  [--output <path>] [--code ] [ --sgml ] input_file

Options:
    --outdir         Output directory (default '.')
    --code           Generate C and header files.
    --sgml           Generate wait_event_types.sgml.

generate-wait_event_types.pl generates the SGML documentation and code
related to wait events.  This should use wait_event_names.txt in input, or
an input file with a compatible format.

Report bugs to <pgsql-bugs\@lists.postgresql.org>.
EOM
}
