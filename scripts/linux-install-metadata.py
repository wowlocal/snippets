#!/usr/bin/env python3
"""Generate install-prefix-specific metadata. Never change desktop preferences."""
import argparse
from pathlib import Path
import shlex
import unicodedata
import xml.etree.ElementTree as ET


def desktop_argument(path):
    text = str(path)
    if not path.is_absolute() or len(text.encode()) > 4096 or '=' in text or any(
            unicodedata.category(c) == 'Cc' for c in text):
        raise ValueError('The installation path cannot be used in a desktop entry.')
    value = '"'
    for character in text:
        if character == '\\':
            value += '\\\\\\\\'
        elif character in '"$`':
            value += '\\\\' + character
        elif character == '%':
            value += '%%'
        else:
            value += character
    return value + '"'


def generate(destination, template, output, gnome):
    executable = desktop_argument(destination / 'snippets')
    lines = []
    for line in template.read_text().splitlines():
        if line == 'Exec=snippets' or line.startswith('Exec=snippets '):
            # GLib validates argv[0] before expanding %% in arguments. env
            # executes the absolute path without invoking a shell (same as the
            # app's launch-at-login entry).
            line = 'Exec=/usr/bin/env -- ' + executable + line[len('Exec=snippets'):]
        lines.append(line)
    output.mkdir(parents=True, exist_ok=True)
    (output / template.name).write_text('\n'.join(lines) + '\n')
    if not gnome:
        return
    component = ET.Element('component')
    for key, value in {
        'name': 'org.freedesktop.IBus.Snippets',
        'description': 'Snippets text expansion',
        'exec': shlex.join([str(destination / 'snippets-ibus'), '--ibus']),
        'version': '0.1.0', 'license': 'MIT', 'author': 'Snippets',
        'homepage': 'https://github.com/wowlocal/snippets', 'textdomain': '',
    }.items():
        ET.SubElement(component, key).text = value
    engine = ET.SubElement(ET.SubElement(component, 'engines'), 'engine')
    for key, value in {
        'name': 'snippets', 'longname': 'Snippets',
        'description': 'Snippets text expansion', 'language': 'en',
        'license': 'MIT', 'author': 'Snippets', 'layout': 'default',
        'icon': 'com.khm.snippets.linux', 'symbol': 'S',
    }.items():
        ET.SubElement(engine, key).text = value
    ET.indent(component)
    ET.ElementTree(component).write(output / 'snippets.xml', encoding='utf-8',
                                    xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--template', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--gnome', action='store_true')
    args = parser.parse_args()
    try:
        generate(args.destination, args.template, args.output, args.gnome)
    except ValueError as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
