// Reference transform: pdf_cos 3.7.0, Apache-2.0; see third_party/pdf_cos/LICENSE.
import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const source=fs.readFileSync(path.join(root,'third_party/pdf_cos/lib/src/filters/jpx.dart'),'utf8');
const original=fs.readFileSync(path.join(root,'tool/fixtures/jpx-synthesis-reference.txt'),'utf8').replace('void _synthesize1d(', 'void reference(');
const check=fs.readFileSync(path.join(root,'tool/fixtures/jpx-equivalence-driver.txt'),'utf8');
const directory=path.join(root,'build/jpx-equivalence');fs.mkdirSync(directory,{recursive:true});
const target=path.join(directory,'check.dart');
fs.writeFileSync(target,"import 'dart:typed_data';\nimport 'dart:math';\n"+original+"\n"+source.slice(source.indexOf('void _synthesize1d('))+"\n"+check);
cp.execFileSync(process.argv[2]||'dart',[target],{stdio:'inherit'});
