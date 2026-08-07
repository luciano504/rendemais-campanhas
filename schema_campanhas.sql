-- =====================================================================
-- RENDE MAIS CAMPANHAS · verbas de fomento por item — schema v5
--
-- RODAR NO MESMO PROJETO SUPABASE DO DATA CRÍTICA (estciwkeihmokvlnvaum).
-- O app de verbas NÃO cria cadastro novo: ele lê as tabelas que o sync do
-- VR já alimenta para o Data Crítica —
--     produtos(ean, descricao, secao)
--     produtos_loja(ean, loja, id_fornecedor, nome_fornecedor,
--                   ultimo_custo, preco_venda, estoque, vmd, ...)
--     vendas_dia(ean, loja, data, qtd)        <- apuração da verba
--     usuarios(id, nome, papel, loja, pin_hash, ativo, ids_fornecedor)
-- usuarios.id é UUID neste projeto. Logins e PINs são os mesmos. Aqui só entram os objetos NOVOS das verbas.
--
-- Fornecedor é identificado pela RAZÃO SOCIAL AGLUTINADA (mesma regra do
-- relatório mensal: upper + trim + espaços únicos), somando os CNPJs.
-- Verba unitária = preço cheio − preço sugerido pelo fornecedor.
-- =====================================================================

-- ---------- 1. FORNECEDORES AGLUTINADOS (view sobre produtos_loja) ----------
create or replace function fn_chave_fornecedor(p_nome text) returns text as $$
  select upper(regexp_replace(btrim(coalesce(p_nome,'(sem nome)')), '\s+', ' ', 'g'));
$$ language sql immutable;

create or replace view v_fornecedores_verbas as
select fn_chave_fornecedor(nome_fornecedor)      as fornecedor_chave,
       min(nome_fornecedor)                      as nome_fornecedor,
       array_agg(distinct id_fornecedor)         as ids_fornecedor,
       count(distinct ean)                       as itens
from produtos_loja
where id_fornecedor is not null
group by 1;

-- lista leve usada pelo app na abertura (id + nome, sem varrer tudo no cliente)
create or replace view v_fornecedores_lista as
select distinct id_fornecedor, nome_fornecedor
from produtos_loja
where id_fornecedor is not null;

-- marcação dos PRINCIPAIS fornecedores (sobem no topo ao criar campanha)
create table if not exists fornecedores_principais (
  fornecedor_chave text primary key,
  marcado_em       timestamptz not null default now(),
  marcado_por      uuid references usuarios(id)
);

-- ---------- 2. REPRESENTANTES ----------
create table if not exists representantes (
  id               bigserial primary key,
  fornecedor_chave text not null,                  -- razão social aglutinada
  nome             text not null,
  cargo            text,
  email            text,
  telefone         text,
  recebe_alertas   boolean not null default true,
  usuario_id       uuid references usuarios(id), -- se também tem login
  ativo            boolean not null default true,
  criado_em        timestamptz not null default now()
);
create index if not exists ix_rep_forn on representantes(fornecedor_chave) where ativo;

-- ---------- 3. MARGEM-ALVO POR SEÇÃO (piso de referência) ----------
create table if not exists secoes_margem (
  secao         text primary key,                  -- mesmo valor de produtos.secao
  margem_alvo   numeric(6,4) not null default 0.20,
  atualizado_em timestamptz not null default now()
);

-- ---------- 4. CAMPANHAS ----------
create table if not exists campanhas (
  id                bigserial primary key,
  fornecedor_chave  text   not null,
  ids_fornecedor    bigint[] not null default '{}',   -- CNPJs aglutinados no momento
  nome              text   not null,
  inicio            date   not null,                  -- vigência GERAL
  fim               date   not null,
  orcamento_total   numeric(14,2) not null,           -- teto de verba da campanha
  lojas             text[] not null,                  -- {'L01','L02',...}
  representante_id  bigint references representantes(id),
  origem            text not null default 'fornecedor' check (origem in ('fornecedor','gestor')),
  pagamento         text not null default 'pos'       check (pagamento in ('antecipado','pos')),
  pago_em           date, valor_pago numeric(14,2), faturado_em date,
  status            text not null default 'rascunho'
    check (status in ('rascunho','aguardando_aceite','aguardando_fornecedor','vigente',
                      'recusada','suspensa_orcamento','estancada','encerrada')),
  -- aguardando_aceite     = fornecedor propôs, falta o Gestor aceitar
  -- aguardando_fornecedor = Gestor criou, falta o fornecedor aceitar
  criada_em         timestamptz not null default now(),
  criada_por        uuid references usuarios(id),
  decidida_em       timestamptz, decidida_por uuid references usuarios(id),
  observacao        text,
  constraint periodo_valido check (fim >= inicio)
);

create table if not exists campanha_itens (
  id                bigserial primary key,
  campanha_id       bigint not null references campanhas(id) on delete cascade,
  ean               text   not null,                 -- casa com produtos.ean
  descricao         text,                            -- congelada para histórico
  secao             text,
  preco_sugerido    numeric(12,2) not null,          -- preço promocional
  verba_sugerida    numeric(12,4) not null,          -- preco_ref − preco_sugerido
  verba_unitaria    numeric(12,4) not null,          -- o que o fornecedor oferece
  orcamento_item    numeric(14,2),                   -- teto do item (null = só o da campanha)
  inicio_item       date, fim_item date,             -- vigência do item (null = herda)
  custo_ref         numeric(12,4) not null,          -- maior ultimo_custo nas lojas da campanha
  preco_ref         numeric(12,2) not null,          -- maior preco_venda (preço cheio)
  margem_alvo_ref   numeric(6,4)  not null,
  status            text not null default 'aguardando_aceite'
    check (status in ('aguardando_aceite','aguardando_fornecedor','aprovado','recusado',
                      'suspenso_orcamento','estancado','encerrado')),
  decidido_em       timestamptz, decidido_por uuid references usuarios(id), motivo text,
  unique (campanha_id, ean)
);

create table if not exists campanha_eventos (
  id          bigserial primary key,
  campanha_id bigint not null references campanhas(id) on delete cascade,
  item_id     bigint references campanha_itens(id) on delete cascade,
  tipo        text not null,      -- proposta, alteracao, aceite, recusa, aumento_orcamento,
                                  -- estancar, suspensao, reativacao, encerramento
  autor_id    uuid references usuarios(id), papel text,
  de jsonb, para jsonb, mensagem text,
  criado_em   timestamptz not null default now()
);

create table if not exists orcamento_ajustes (
  id          bigserial primary key,
  campanha_id bigint not null references campanhas(id) on delete cascade,
  item_id     bigint references campanha_itens(id) on delete cascade,   -- null = campanha
  de numeric(14,2), para numeric(14,2),
  autor_id    uuid references usuarios(id),
  criado_em   timestamptz not null default now()
);

create table if not exists alertas_verba (
  id          bigserial primary key,
  campanha_id bigint not null references campanhas(id) on delete cascade,
  item_id     bigint references campanha_itens(id) on delete cascade,
  nivel       text not null check (nivel in ('atencao','critico')),
  tipo        text not null,   -- 70_item, 70_campanha, estouro_item, estouro_campanha,
                               -- fim_periodo_item, fim_periodo_campanha
  mensagem    text not null, lido boolean not null default false,
  criado_em   timestamptz not null default now(),
  unique (tipo, campanha_id, item_id)
);

-- ---------- 5. APURAÇÃO: vendas_dia × verba unitária ----------
-- Sem tabela nova: a verba consumida sai direto das vendas que o sync do VR
-- já grava, respeitando as lojas da campanha e o período de cada item.
create or replace view v_consumo_item as
select ci.id as item_id, ci.campanha_id,
       coalesce(sum(v.qtd),0)                        as unidades,
       coalesce(sum(v.qtd),0) * ci.verba_unitaria    as verba_consumida,
       ci.orcamento_item,
       case when coalesce(ci.orcamento_item,0) = 0 then null
            else coalesce(sum(v.qtd),0) * ci.verba_unitaria / ci.orcamento_item end as pct_item
from campanha_itens ci
join campanhas c on c.id = ci.campanha_id
left join vendas_dia v
       on ltrim(regexp_replace(v.ean,'\D','','g'),'0') = ltrim(regexp_replace(ci.ean,'\D','','g'),'0')
      and v.loja = any (c.lojas)
      and v.data between coalesce(ci.inicio_item, c.inicio) and coalesce(ci.fim_item, c.fim)
group by ci.id, c.id;

create or replace view v_consumo_campanha as
select c.id as campanha_id, c.orcamento_total,
       coalesce(sum(ci.verba_consumida),0) as verba_consumida,
       coalesce(sum(ci.unidades),0)        as unidades,
       case when c.orcamento_total = 0 then null
            else coalesce(sum(ci.verba_consumida),0) / c.orcamento_total end as pct_campanha
from campanhas c
left join v_consumo_item ci on ci.campanha_id = c.id
group by c.id;

create or replace view v_financeiro_campanha as
select c.id as campanha_id, c.fornecedor_chave, c.nome, c.pagamento, c.orcamento_total,
       vc.verba_consumida,
       case when c.pagamento='antecipado' then coalesce(c.valor_pago,c.orcamento_total) else 0 end as ja_pago,
       case when c.pagamento='antecipado'
            then greatest(0, coalesce(c.valor_pago,c.orcamento_total) - vc.verba_consumida) else 0 end as saldo_adiantamento,
       case when c.pagamento='pos' then vc.verba_consumida else 0 end as a_faturar,
       c.status
from campanhas c join v_consumo_campanha vc on vc.campanha_id = c.id;

-- ---------- 6. MOTOR DE LIMITES (rodar após cada sync de vendas) ----------
-- 70% do orçado -> alerta; 100% do item -> item suspenso;
-- 100% da campanha -> TODAS as promoções desfeitas; fim do período -> encerra.
create or replace function fn_avaliar_verbas(p_pct numeric default 0.70) returns void as $$
begin
  -- fim de vigência
  update campanha_itens ci set status='encerrado'
    from campanhas c
   where ci.campanha_id=c.id and ci.status in ('aprovado','suspenso_orcamento')
     and coalesce(ci.fim_item,c.fim) < current_date;
  update campanhas set status='encerrada'
   where status in ('vigente','suspensa_orcamento') and fim < current_date;

  -- estouro por item
  insert into alertas_verba(campanha_id,item_id,nivel,tipo,mensagem)
  select ci.campanha_id, ci.id, 'critico','estouro_item',
         'Orçamento do item esgotado — promoção suspensa. Aumente o orçamento ou estanque o item.'
  from campanha_itens ci join v_consumo_item vi on vi.item_id=ci.id
  where ci.status='aprovado' and coalesce(ci.orcamento_item,0)>0
    and vi.verba_consumida >= ci.orcamento_item
  on conflict do nothing;

  update campanha_itens ci set status='suspenso_orcamento'
    from v_consumo_item vi
   where vi.item_id=ci.id and ci.status='aprovado'
     and coalesce(ci.orcamento_item,0)>0 and vi.verba_consumida >= ci.orcamento_item;

  -- 70% por item
  insert into alertas_verba(campanha_id,item_id,nivel,tipo,mensagem)
  select ci.campanha_id, ci.id, 'atencao','70_item','Item atingiu 70% do orçamento de verba.'
  from campanha_itens ci join v_consumo_item vi on vi.item_id=ci.id
  where coalesce(ci.orcamento_item,0)>0 and vi.verba_consumida >= p_pct*ci.orcamento_item
  on conflict do nothing;

  -- estouro da campanha: desfaz TODAS as promoções
  insert into alertas_verba(campanha_id,nivel,tipo,mensagem)
  select c.id,'critico','estouro_campanha',
         'Orçamento da campanha esgotado — todas as promoções foram desfeitas. Aumente o orçamento para reativar ou estanque a campanha.'
  from campanhas c join v_consumo_campanha vc on vc.campanha_id=c.id
  where c.status='vigente' and vc.verba_consumida >= c.orcamento_total
  on conflict do nothing;

  update campanha_itens ci set status='suspenso_orcamento'
    from campanhas c join v_consumo_campanha vc on vc.campanha_id=c.id
   where ci.campanha_id=c.id and ci.status='aprovado'
     and c.status='vigente' and vc.verba_consumida >= c.orcamento_total;

  update campanhas c set status='suspensa_orcamento'
    from v_consumo_campanha vc
   where vc.campanha_id=c.id and c.status='vigente' and vc.verba_consumida >= c.orcamento_total;

  -- 70% da campanha
  insert into alertas_verba(campanha_id,nivel,tipo,mensagem)
  select c.id,'atencao','70_campanha','Campanha atingiu 70% do orçamento de verba.'
  from campanhas c join v_consumo_campanha vc on vc.campanha_id=c.id
  where c.orcamento_total>0 and vc.verba_consumida >= p_pct*c.orcamento_total
  on conflict do nothing;
end $$ language plpgsql;

-- ---------- 7. FÓRMULAS ----------
-- verba unitária sugerida = preço cheio (sem promoção) − preço sugerido
create or replace function fn_verba_sugerida(p_preco_cheio numeric, p_preco_promo numeric)
returns numeric as $$ select greatest(0, round(p_preco_cheio - p_preco_promo, 4)); $$ language sql immutable;

-- margem % com a verba: (preco_promo − custo + verba) / preco_promo
create or replace function fn_margem_com_verba(p_preco_promo numeric, p_custo numeric, p_verba numeric)
returns numeric as $$
  select case when coalesce(p_preco_promo,0)=0 then 0
              else round((p_preco_promo - (p_custo - p_verba))/p_preco_promo, 4) end;
$$ language sql immutable;

-- ---------- 8. BUSCA DE ITEM POR CÓDIGO DE BARRAS ----------
-- casa o EAN com e sem zero à esquerda e diz se o item é da base do fornecedor
create or replace function fn_produto_por_ean(p_ean text, p_fornecedor_chave text)
returns table (ean text, descricao text, secao text, nome_fornecedor text, e_do_fornecedor boolean) as $$
  select p.ean, p.descricao, p.secao, pl.nome_fornecedor,
         fn_chave_fornecedor(pl.nome_fornecedor) = p_fornecedor_chave
  from produtos p
  join produtos_loja pl on pl.ean = p.ean
  where ltrim(regexp_replace(p.ean,'\D','','g'),'0') = ltrim(regexp_replace(p_ean,'\D','','g'),'0')
  limit 1;
$$ language sql stable;

create index if not exists ix_produtos_ean_norm
  on produtos (ltrim(regexp_replace(ean,'\D','','g'),'0'));
create index if not exists ix_pl_fornecedor on produtos_loja(id_fornecedor);
create index if not exists ix_itens_campanha on campanha_itens(campanha_id);
create index if not exists ix_itens_ean      on campanha_itens(ean);
create index if not exists ix_alertas_verba  on alertas_verba(campanha_id, lido);
create index if not exists ix_eventos_camp   on campanha_eventos(campanha_id, criado_em desc);

-- ---------- 9. PERMISSÃO DE USO DO MÓDULO ----------
alter table usuarios add column if not exists acesso_verbas boolean not null default true;

-- ---------- 10. AGENDAMENTO SUGERIDO ----------
-- depois de cada sync do VR (as mesmas 4×/dia do Data Crítica):
--   select fn_avaliar_verbas(0.70);
