#!/usr/bin/env python3
"""The one table build of lfrPulls and lfrPullsTriage.

Each table has " | " between the columns, a border on each side, and one line
of - under the header. The rows have no line between them, so the table is
short and easy to read. A column with only numbers aligns to the right.

Python code imports render(). Shell code pipes tab-separated lines to this file:
the first line is the header. With --marked, the first field of each line is
the row marker of _lfrPullsPaint. It stays in front of the line, outside the
table, and the lines of _ get the marker R, which paints as plain text.
"""

import sys
import unicodedata


def width(text):
	"""Return the number of terminal cells that the text uses."""
	total = 0

	for char in text:
		if unicodedata.combining(char):
			continue

		total += 2 if unicodedata.east_asian_width(char) in "WF" else 1

	return total


def is_number(value):
	return value.replace(".", "", 1).lstrip("-").isdigit()


def render(headers, rows, markers=None):
	"""Return the lines of the table. markers, if given, has one per row."""
	headers = [str(header) for header in headers]
	cells = [
		[str(cell) for cell in row] + [""] * (len(headers) - len(row))
		for row in rows]
	widths = [
		max([width(header)] + [width(row[index]) for row in cells])
		for index, header in enumerate(headers)]
	numeric = [
		bool(cells) and all(is_number(row[index]) for row in cells)
		for index in range(len(headers))]

	def line(values):
		return "| " + " | ".join(
			" " * (size - width(value)) + value if right
			else value + " " * (size - width(value))
			for value, size, right in zip(values, widths, numeric)) + " |"

	rule = "|" + "|".join("-" * (size + 2) for size in widths) + "|"

	if markers is None:
		return [line(headers), rule] + [line(row) for row in cells]

	return ["H " + line(headers), "R " + rule] + [
		f"{marker} " + line(row) for marker, row in zip(markers, cells)]


def main():
	marked = "--marked" in sys.argv[1:]
	records = [
		record.rstrip("\n").split("\t") for record in sys.stdin
		if record.strip()]

	if not records:
		return

	if marked:
		headers = records[0][1:]
		markers = [record[0] for record in records[1:]]
		rows = [record[1:] for record in records[1:]]
	else:
		headers, rows, markers = records[0], records[1:], None

	print("\n".join(render(headers, rows, markers)))


if __name__ == "__main__":
	main()
