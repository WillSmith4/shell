#!/usr/bin/env python3
"""Restore the standard data files matching the supplied PROJ 9.1.0 framework."""
import hashlib
from contextlib import closing
from pathlib import Path
import re
import shutil
import sqlite3
import tarfile
import tempfile
import urllib.request

root=Path(__file__).resolve().parents[1]
output=root/'Resources/proj'
if (output/'proj.db').is_file():
    raise SystemExit(0)
binary=root/'.build/installed-app/Frameworks/libproj.framework/libproj'
if b'Rel. 9.1.0, September 1st, 2022' not in binary.read_bytes():
    raise SystemExit('PROJ data recipe does not match the supplied library version.')
cache=root/'.build/proj-data'
cache.mkdir(parents=True,exist_ok=True)
archive=cache/'proj-9.1.0.tar.gz'
if not archive.exists():
    urllib.request.urlretrieve('https://download.osgeo.org/proj/proj-9.1.0.tar.gz',archive)
if hashlib.sha256(archive.read_bytes()).hexdigest()!='81b2239b94cad0886222cde4f53cb49d34905aad2a1317244a0c30a553db2315':
    raise SystemExit('PROJ source checksum mismatch')
with tempfile.TemporaryDirectory(dir=cache) as temporary:
    stage=Path(temporary)
    with tarfile.open(archive) as source:
        source.extractall(stage,filter='data')
    data=stage/'proj-9.1.0/data'
    files=re.findall(r'\$\{SQL_DIR\}/([^"\n]+)',(data/'sql_filelist.cmake').read_text())
    sql=''.join((data/'sql'/name).read_text(encoding='utf-8') for name in files)
    db=stage/'proj.db'
    with closing(sqlite3.connect(db)) as connection:
        connection.executescript(sql.replace('${PROJ_VERSION}','9.1.0'))
        assert connection.execute('PRAGMA integrity_check').fetchone()==('ok',)
        assert connection.execute("SELECT value FROM metadata WHERE key='PROJ.VERSION'").fetchone()==('9.1.0',)
        assert connection.execute("SELECT count(*) FROM geodetic_crs WHERE auth_name='EPSG' AND code=4326").fetchone()==(1,)
    output.mkdir(parents=True,exist_ok=True)
    shutil.copy2(db,output/'proj.db')
    names=['proj.ini','world','other.extra','nad27','GL27','nad83','nad.lst','CH','ITRF2000','ITRF2008','ITRF2014']
    for name in names:
        shutil.copy2(data/name,output/name)
    for pattern in ['*.json','*.gsb','*.gtx']:
        for item in data.glob(pattern): shutil.copy2(item,output/item.name)
    shutil.copy2(stage/'proj-9.1.0/COPYING',output/'COPYING')
print('Generated and verified PROJ 9.1.0 data for the supplied libproj framework')
