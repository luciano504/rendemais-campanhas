-- =====================================================================
-- RENDE MAIS CAMPANHAS · cadastro MANUAL de fornecedores e itens
-- Rodar no mesmo projeto do Data Crítica (estciwkeihmokvlnvaum).
-- Complementa o schema_campanhas.sql — não altera nada do que já existe.
--
-- Para quê:
--  1) fornecedor que ainda não aparece em produtos_loja (indústria nova,
--     representante, marca sem entrada registrada) e itens fora da base;
--  2) AGRUPAR num cadastro só várias razões sociais do mesmo grupo
--     (ex.: LACTALIS DO BRASIL + LACTALIS COMERCIAL DISTRIBUIDORA),
--     somando os id_fornecedor — o portfólio dos três vira um portfólio só.
-- =====================================================================

create table if not exists fornecedores_manuais (
  fornecedor_chave text primary key,       -- razão social normalizada (upper/trim)
  nome             text not null,          -- razão social como será exibida
  cnpjs            text[] not null default '{}',
  ids_fornecedor   bigint[] not null default '{}',  -- opcional: amarra ao VR
  chaves_absorvidas text[] not null default '{}',  -- razões sociais que este cadastro substitui
                                                   -- (ex.: LACTALIS DO BRASIL + LACTALIS COMERCIAL -> LACTALIS)
  observacao       text,
  ativo            boolean not null default true,
  criado_em        timestamptz not null default now(),
  criado_por       uuid references usuarios(id)
);

-- itens que o gestor associa a um fornecedor manualmente
-- (custo/preco só são usados quando o EAN não existe em produtos_loja)
create table if not exists fornecedor_itens_manuais (
  id               bigserial primary key,
  fornecedor_chave text not null,
  ean              text not null,
  descricao        text,
  secao            text,
  custo            numeric(12,4),
  preco            numeric(12,2),
  criado_em        timestamptz not null default now(),
  criado_por       uuid references usuarios(id),
  unique (fornecedor_chave, ean)
);
create index if not exists ix_fim_forn on fornecedor_itens_manuais(fornecedor_chave);

-- lista única: fornecedores do VR + os cadastrados à mão
create or replace view v_fornecedores_todos as
select fornecedor_chave, nome_fornecedor as nome, ids_fornecedor, itens, false as manual
from v_fornecedores_verbas
union all
select fm.fornecedor_chave, fm.nome, fm.ids_fornecedor,
       (select count(*) from fornecedor_itens_manuais i where i.fornecedor_chave = fm.fornecedor_chave),
       true
from fornecedores_manuais fm
where fm.ativo
  and not exists (select 1 from v_fornecedores_verbas v
                  where v.fornecedor_chave = fm.fornecedor_chave);

-- para quem já rodou a versão anterior deste arquivo:
alter table fornecedores_manuais add column if not exists chaves_absorvidas text[] not null default '{}';
