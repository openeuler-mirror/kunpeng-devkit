import os
import re

DIR = r"m:\Users\s00850861\data\code\kunpeng-devkit1\migration\application-migration\cpp-kunpeng-migration"

mapping = {'A': '1', 'B': '2', 'C': '3', 'D': '4', 'E': '5', 'F': '6'}

changed_files = []

for root, dirs, files in os.walk(DIR):
    for f in files:
        if not f.endswith('.md'):
            continue
        path = os.path.join(root, f)
        with open(path, 'r', encoding='utf-8') as fh:
            content = fh.read()
        orig = content

        # 1. Compound stage phrases first (before individual letter replacements)
        content = content.replace('阶段 A、B', '阶段 1、2')
        content = content.replace('阶段 D 和 E', '阶段 4 和 5')
        content = content.replace('阶段 D、E、F2', '阶段 4、5、6')
        content = content.replace('阶段 A 和 B', '阶段 1 和 2')

        # 2. Stage F2 before stage F (so "F2" doesn't become "F2"→"6"+"2")
        content = content.replace('阶段 F2', '阶段 6')

        # 3. Individual stage labels: 阶段 X → 阶段 N
        for letter, num in mapping.items():
            content = content.replace(f'阶段 {letter}', f'阶段 {num}')

        # 4. 阶段编号 line
        content = content.replace(
            '阶段编号：A / B / C / D / E / F',
            '阶段编号：1 / 2 / 3 / 4 / 5 / 6'
        )

        # 5. Section refs: X.Y → N.Y where X is A-F (e.g., C.1→3.1, D.1.1→4.1.1, E.2.1→5.2.1)
        #    Negative lookbehind ensures the letter is not part of a larger word (e.g., not "TableA.1")
        content = re.sub(
            r'(?<![A-Za-z])([A-F])\.([0-9])',
            lambda m: mapping[m.group(1)] + '.' + m.group(2),
            content
        )

        # 6. Code identifiers: file names and log keys
        content = content.replace('stage_a', 'stage_1')
        content = content.replace('stage_b', 'stage_2')
        content = content.replace('PHASE_A', 'PHASE_1')

        if content != orig:
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(content)
            rel = os.path.relpath(path, DIR)
            changed_files.append(rel)
            print(f'Updated: {rel}')

print(f'\nTotal: {len(changed_files)} files updated')
