#!/usr/bin/env python3
"""Trace synthesized sequential clock pins to the clock report's actual targets.

PDS query results are deferred command handles, not Tcl lists. This reader checks
the emitted structural VM and clock report; native pin queries separately verify
that the constrained objects exist. It never infers a domain from a net's name.
"""
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
import re


def identifier(value):
    return re.sub(r"\s+", "", value.strip().lstrip("\\"))


def closing(text, start):
    depth, quoted, escaped = 0, False, False
    for pos in range(start, len(text)):
        ch = text[pos]
        if quoted:
            if ch == '"' and not escaped:
                quoted = False
            escaped = ch == "\\" and not escaped
            continue
        if ch == '"':
            quoted = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return pos
    raise ValueError("unclosed structural netlist expression")


@dataclass
class Instance:
    kind: str
    name: str
    ports: dict
    attributes: str


@dataclass
class Scope:
    path: str
    module: str
    parent: object = None
    binding: object = None


class ClockNetlist:
    @staticmethod
    def scalar_outputs(cell):
        if cell.kind.startswith('GTP_DFF'):
            widths = {'Q': 1}
        elif cell.kind == 'GTP_RAM32X2X4':
            widths = {f'DO{i}': 2 for i in range(4)}
        elif cell.kind in ('GTP_RAM32X2DP', 'GTP_RAM32X1DP'):
            widths = {'DO': 2 if cell.kind == 'GTP_RAM32X2DP' else 1}
        else:
            raise ValueError(f'unsupported FIFO payload primitive {cell.kind}')
        return [f'{port}[{bit}]' if width > 1 else port
                for port, width in widths.items() if cell.ports.get(port)
                for bit in range(width)]

    def __init__(self, text, top, clock_rows, spec, clock_paths=None):
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        self.roots = {}
        for domain, clock in spec['clocks'].items():
            rows = [r for r in clock_rows if r['Clock Name'] == clock]
            if len(rows) != 1:
                raise ValueError(f"clock report missing/duplicate {clock}")
            row = rows[0]
            # 原生报告会把分数周期显示为有限小数；仅按该字段的末位精度核对。
            # ROUND_HALF_UP 对应半个末位单位的范围，不引入固定比例容差。
            reported_period = Decimal(row['Period'])
            expected_period = Decimal(spec['periods_ns'][domain])
            if expected_period.quantize(reported_period, rounding=ROUND_HALF_UP) != reported_period:
                raise ValueError(f"clock period differs from measurement {clock}")
            targets = row['Targets'].strip().strip('{}').split()
            if not targets:
                raise ValueError(f"clock report has no target {clock}")
            for target in targets:
                target = re.sub(r'^[tpc]:', '', target)
                if target in self.roots:
                    raise ValueError(f"ambiguous clock target {target}")
                self.roots[target] = domain
        blocks = list(re.finditer(r'^(?:\(\*[^\n]*\*\)\s*)?module\s+(\w+)\s*\((.*?)^endmodule', text, re.M | re.S))
        names = {m[1] for m in blocks}
        self.modules = {}
        prefix = re.compile(r'^[ \t]*(?P<attr>\(\*[^\n]*\*\))?[ \t]*(?P<kind>[A-Za-z_]\w*)[ \t]+', re.M)
        ports = re.compile(r'\.(\\\S+|[A-Za-z_]\w*)\s*\(([^()]*)\)', re.S)
        instance_name = re.compile(r'\s*(\\\S+|[A-Za-z_]\w*)\s*\(')
        for match in blocks:
            body = match[2]
            end = body.find(');')
            if end < 0:
                raise ValueError(f"missing module header {match[1]}")
            header, body = body[:end], body[end + 2:]
            directions = {}
            for direction, declaration in re.findall(r'\b(input|output|inout)\b([^,\n]*)', header):
                name = re.search(r'(\\\S+|[A-Za-z_]\w*)\s*$', declaration)
                if name:
                    directions[identifier(name[1])] = direction
            inputs = {name for name, direction in directions.items() if direction == 'input'}
            instances = {}
            for item in prefix.finditer(body):
                kind = item['kind']
                # Clock gates made from arbitrary LUT logic remain unresolved.
                if kind not in names and not kind.startswith(('GTP_DFF', 'GTP_DRM', 'GTP_RAM',
                        'GTP_CLK', 'GTP_GPLL', 'GTP_PPLL', 'GTP_INBUF')):
                    continue
                pos = item.end()
                if body[pos:pos + 1] == '#':
                    pos += 1
                    while body[pos].isspace():
                        pos += 1
                    if body[pos] != '(':
                        raise ValueError('unsupported primitive parameters')
                    pos = closing(body, pos) + 1
                name = instance_name.match(body, pos)
                if not name:
                    raise ValueError(f"unsupported instance {kind}")
                start = name.end() - 1
                stop = closing(body, start)
                connected = {identifier(p): identifier(n) for p, n in ports.findall(body[start + 1:stop])}
                key = identifier(name[1])
                if key in instances:
                    raise ValueError(f"duplicate instance {match[1]}/{key}")
                instances[key] = Instance(kind, key, connected, item['attr'] or '')
            aliases = {}
            for lhs, rhs in re.findall(r'\bassign\s+(.*?)\s*=\s*([^;]+);', body):
                lhs, rhs = identifier(lhs), identifier(rhs)
                if re.fullmatch(r'[\w.$/\[\]:]+', lhs) and re.fullmatch(r'[\w.$/\[\]:]+', rhs):
                    aliases[lhs] = rhs
            self.modules[match[1]] = dict(inputs=inputs, directions=directions, instances=instances, aliases=aliases,
                                          encrypted='`pragma protect begin_protected' in body)
        if top not in self.modules:
            raise ValueError(f"netlist top missing {top}")
        self.cells, self.scopes, self.clock_cache, self.native_aliases = {}, {}, {}, {}
        self._walk(Scope('', top))
        self.reported_clock_nets, self.clock_evidence = {}, {}
        # DDR PLL internals remain encrypted. Use only the native report's clock
        # segment after its declared target and before the launching register.
        for domain, clock in spec['clocks'].items():
            row = (clock_paths or {}).get(clock)
            if row is None:
                continue
            if row['Launch Clock'] != clock or row['Capture Clock'] != clock:
                raise ValueError(f'invalid same-domain clock witness {clock}')
            resources = [r.split(' (', 1)[0] for r in row['logical_resources']]
            end = resources.index(row['Start Point'])
            candidates = [(i, name) for i, name in enumerate(resources[:end])
                          if self.roots.get(name) == domain and any(
                              name.startswith(scope.path + '/') and self.modules[scope.module]['encrypted']
                              for scope in self.scopes.values())]
            if not candidates:
                continue
            begin, target = candidates[-1]
            witness = dict(domain=domain, target=target, launch_pin=row['Start Point'],
                           clock_segment=resources[begin:end])
            self.clock_evidence[clock] = witness
            for name in resources[begin:end]:
                if name in self.reported_clock_nets and self.reported_clock_nets[name][0] != domain:
                    raise ValueError(f'ambiguous native clock-tree witness {name}')
                self.reported_clock_nets[name] = (domain, target)

    def _walk(self, scope):
        self.scopes[scope.path] = scope
        for inst in self.modules[scope.module]['instances'].values():
            path = f'{scope.path}/{inst.name}'.lstrip('/')
            if inst.kind in self.modules:
                self._walk(Scope(path, inst.kind, scope, inst))
            else:
                if path in self.cells:
                    raise ValueError(f"ambiguous leaf {path}")
                self.cells[path] = (scope, inst)

    def _trace(self, scope, net, seen):
        key = (scope.path, net)
        if key in self.clock_cache:
            domain, suffix = self.clock_cache[key]
            return domain, [*seen, *suffix]
        domain, trace = self._trace_uncached(scope, net, seen)
        self.clock_cache[key] = (domain, trace[len(seen):])
        return domain, trace

    def _trace_uncached(self, scope, net, seen):
        node = (scope.path, net)
        if node in seen:
            raise ValueError(f"clock net cycle at {node}")
        seen = [*seen, node]
        full = f'{scope.path}/{net}'.lstrip('/')
        if full in self.roots:
            return self.roots[full], seen
        if full in self.reported_clock_nets:
            domain, target = self.reported_clock_nets[full]
            return domain, [*seen, (target, 'native timing clock segment across encrypted IP')]
        module = self.modules[scope.module]
        if net in module['aliases']:
            return self._trace(scope, module['aliases'][net], seen)
        if net in module['inputs'] and scope.parent is not None:
            if net not in scope.binding.ports:
                raise ValueError(f"missing parent clock connection {full}")
            return self._trace(scope.parent, scope.binding.ports[net], seen)
        drivers = []
        for inst in module['instances'].values():
            if inst.kind in self.modules:
                child = self.scopes[f'{scope.path}/{inst.name}'.lstrip('/')]
                for port, connected in inst.ports.items():
                    if connected == net and self.modules[inst.kind]['directions'].get(port) == 'output':
                        drivers.append(self._trace(child, port, seen))
                continue
            for pin in ('CLKOUT', 'CLKOUT0', 'CLKOUT1', 'CLKOUT2', 'CLKOUT3',
                        'CLKOUT4', 'CLKOUT5', 'CLKOUTPHY', 'O'):
                if inst.ports.get(pin) != net:
                    continue
                target = f'{scope.path}/{inst.name}/{pin}'.lstrip('/')
                if target in self.roots:
                    drivers.append((self.roots[target], [*seen, (target, 'clock report target')]))
                elif inst.kind == 'GTP_CLKBUFG' and pin == 'CLKOUT':
                    drivers.append(self._trace(scope, inst.ports['CLKIN'], seen))
                elif inst.kind in ('GTP_INBUF', 'GTP_INBUFDS') and pin == 'O':
                    drivers.append(self._trace(scope, inst.ports['I'], seen))
        if len(drivers) != 1:
            raise ValueError(f"unresolved/ambiguous clock driver {full}: {len(drivers)}")
        return drivers[0]

    def pin(self, name):
        cell, separator, pin = name.rpartition('/')
        if cell not in self.cells and cell + '_vname' in self.cells:
            # The VM writer renames an instance when its native name collides
            # with its output net. Accept only that exact Q-net relationship;
            # the unmodified native pin is separately queried in PDS.
            scope, inst = self.cells[cell + '_vname']
            if inst.ports.get('Q') == cell.rsplit('/', 1)[-1]:
                self.native_aliases[cell] = cell + '_vname'
                cell += '_vname'
        if not separator or cell not in self.cells:
            raise ValueError(f"pin cell absent from emitted netlist {name}")
        scope, inst = self.cells[cell]
        if pin not in inst.ports:
            if not re.fullmatch(r'DO[0-3]?\[[01]\]', pin) or pin not in self.scalar_outputs(inst):
                raise ValueError(f"pin absent from emitted netlist {name}")
        return scope, inst, pin

    def domain(self, name):
        scope, inst, pin = self.pin(name)
        if pin in ('CLK', 'WCLK', 'CLKA', 'CLKB'):
            clock = pin
        else:
            clocks = [p for p in ('CLK', 'WCLK') if p in inst.ports]
            if len(clocks) != 1:
                raise ValueError(f"unsupported sequential clock pins {name}")
            clock = clocks[0]
        return self._trace(scope, inst.ports[clock], [])
