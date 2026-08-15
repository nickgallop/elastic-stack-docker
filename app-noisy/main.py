import functools
import json
import time
import xml.etree.ElementTree as ET
from typing import Callable

import asyncio
import elasticapm
import httpx as r
from elasticapm.contrib.starlette import ElasticAPM, make_apm_client
from fastapi import FastAPI, Query
from nicegui import ui

try:
  apm = make_apm_client({
      'SERVICE_NAME': 'noisy_serialization_service',
      'SECRET_TOKEN': 'supersecrettoken',
      # SERVER_URL must be set to "fleet-server" if running as a docker container.
      # if running as a local python script, then set the url to "LOCALHOST"
      'SERVER_URL': 'http://fleet-server:8200',
      'ENVIRONMENT': 'development'
  })
except Exception as e:
  print('failed to create client')

app = FastAPI()

try:
  app.add_middleware(ElasticAPM, client=apm)
except Exception as e:
  print('failed to add APM Middleware')


# ---- JSON ----

def build_nested_dict(depth: int, breadth: int) -> dict:
    node = {'value': f'leaf-{depth}'}
    if depth > 0:
        node['children'] = [build_nested_dict(depth - 1, breadth) for _ in range(breadth)]
    return node


def count_json_nodes(node: dict) -> int:
    return 1 + sum(count_json_nodes(c) for c in node.get('children', []))


def walk_json_naive(node: dict, phase: str) -> int:
    '''Opens one span per node visited - the anti-pattern this app reproduces.'''
    count = 1
    with elasticapm.capture_span(name=f'{phase}.field', span_type='code.custom'):
        for child in node.get('children', []):
            count += walk_json_naive(child, phase)
    return count


def process_json(depth: int, breadth: int, mitigated: bool) -> dict:
    doc = build_nested_dict(depth, breadth)
    if mitigated:
        node_count = count_json_nodes(doc)
        labels = {'node_count': node_count, 'depth': depth, 'breadth': breadth}
        with elasticapm.capture_span(name='serialize.document', span_type='code.custom', labels=labels):
            serialized = json.dumps(doc)
        with elasticapm.capture_span(name='deserialize.document', span_type='code.custom', labels=labels):
            json.loads(serialized)
        spans_emitted = 2
    else:
        serialize_spans = walk_json_naive(doc, 'serialize')
        serialized = json.dumps(doc)
        parsed = json.loads(serialized)
        deserialize_spans = walk_json_naive(parsed, 'deserialize')
        node_count = serialize_spans
        spans_emitted = serialize_spans + deserialize_spans
    return {'format': 'json', 'nodes': node_count, 'spans_emitted': spans_emitted, 'mitigated': mitigated}


# ---- XML ----

def build_nested_xml(depth: int, breadth: int) -> ET.Element:
    el = ET.Element('node', attrib={'value': f'leaf-{depth}'})
    if depth > 0:
        for _ in range(breadth):
            el.append(build_nested_xml(depth - 1, breadth))
    return el


def count_xml_nodes(el: ET.Element) -> int:
    return 1 + sum(count_xml_nodes(c) for c in el)


def walk_xml_naive(el: ET.Element, phase: str) -> int:
    count = 1
    with elasticapm.capture_span(name=f'{phase}.node', span_type='code.custom'):
        for child in el:
            count += walk_xml_naive(child, phase)
    return count


def process_xml(depth: int, breadth: int, mitigated: bool) -> dict:
    doc = build_nested_xml(depth, breadth)
    if mitigated:
        node_count = count_xml_nodes(doc)
        labels = {'node_count': node_count, 'depth': depth, 'breadth': breadth}
        with elasticapm.capture_span(name='serialize.document', span_type='code.custom', labels=labels):
            serialized = ET.tostring(doc)
        with elasticapm.capture_span(name='deserialize.document', span_type='code.custom', labels=labels):
            ET.fromstring(serialized)
        spans_emitted = 2
    else:
        serialize_spans = walk_xml_naive(doc, 'serialize')
        serialized = ET.tostring(doc)
        parsed = ET.fromstring(serialized)
        deserialize_spans = walk_xml_naive(parsed, 'deserialize')
        node_count = serialize_spans
        spans_emitted = serialize_spans + deserialize_spans
    return {'format': 'xml', 'nodes': node_count, 'spans_emitted': spans_emitted, 'mitigated': mitigated}


# ---- routes ----

@app.get('/noisy/json')
async def noisy_json(depth: int = Query(4, ge=1, le=6), breadth: int = Query(4, ge=1, le=6), mitigated: bool = False):
    start = time.perf_counter()
    result = process_json(depth, breadth, mitigated)
    result['elapsed_ms'] = round((time.perf_counter() - start) * 1000, 2)
    return result


@app.get('/noisy/xml')
async def noisy_xml(depth: int = Query(4, ge=1, le=6), breadth: int = Query(4, ge=1, le=6), mitigated: bool = False):
    start = time.perf_counter()
    result = process_xml(depth, breadth, mitigated)
    result['elapsed_ms'] = round((time.perf_counter() - start) * 1000, 2)
    return result


async def io_bound(callback: Callable, *args: any, **kwargs: any):
    '''Makes a blocking function awaitable; pass function as first parameter and its arguments as the rest'''
    return await asyncio.get_event_loop().run_in_executor(None, functools.partial(callback, *args, **kwargs))


def init(fastapi_app: FastAPI) -> None:
    @ui.page('/', title='APM Noisy Trace Demo')
    async def show():
        with ui.header(elevated=True).style('background-color: #c83838').classes('items-center justify-between'):
            ui.markdown('### NOISY SPAN DEMO')
        with ui.footer().style('background-color: #c83838'):
            ui.label('Reproduces excessive / low-value nested APM spans from JSON & XML (de)serialization')

        ui.label('Depth')
        depth_slider = ui.slider(min=1, max=6, value=4).props('label-always')
        ui.label('Breadth')
        breadth_slider = ui.slider(min=1, max=6, value=4).props('label-always')
        mitigated_switch = ui.switch('Mitigated instrumentation (one aggregate span instead of one per node)')

        result_label = ui.label('Click a button to generate a transaction.')

        async def run(fmt: str):
            params = {
                'depth': int(depth_slider.value),
                'breadth': int(breadth_slider.value),
                'mitigated': str(bool(mitigated_switch.value)).lower(),
            }
            res = await io_bound(r.get, f'http://localhost:8000/noisy/{fmt}', params=params)
            result_label.set_text(res.text)

        with ui.row():
            ui.button('Generate JSON', on_click=lambda: run('json'))
            ui.button('Generate XML', on_click=lambda: run('xml'))

    ui.run_with(
        fastapi_app,
        storage_secret='supersecret',  # NOTE setting a secret is optional but allows for persistent storage per user
    )


init(app)

try:
  apm.capture_message('Noisy Trace Demo Loaded')
except Exception as e:
  print('error: ' + str(e))

if __name__ == '__main__':
    print('Please start the app with the "uvicorn" command as shown in the start.sh script')
