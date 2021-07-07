import os
import sys
import argparse
import numpy as np
import pandas as pd
import csv
import plotly
import plotly.graph_objects as go
from plotly.subplots import make_subplots

class BaseCompare:
  def __init__(self, base_folder, feature_folder, export_folder):
    self.base_folder = base_folder
    self.feature_folder = feature_folder
    self.export_folder = export_folder

  def results(self, aggregate_column=None, aggregate_function=None, excludes=[], enum_maps={}, column_maps={}):
    aggregate_columns = []
    if aggregate_column:
      aggregate_columns.append(aggregate_column)

    files = []
    for file in os.listdir(self.base_folder):
      if not file in excludes:
        files.append(file)

    for file in sorted(files):
      base_df = pd.read_csv(os.path.join(self.base_folder, file), index_col=0)
      feature_df = pd.read_csv(os.path.join(self.feature_folder, file), index_col=0)

      try:
        df = feature_df - base_df
      except:
        df = feature_df != base_df
        df = df.astype(int)

      df = df.fillna('NA')
      df.to_csv(os.path.join(self.export_folder, file))    

      # Get results charactersistics of groupby columns
      if file == 'results_characteristics.csv':
        group_df = base_df[aggregate_columns]

      # Write grouped & aggregated results dfs
      if file != 'results_characteristics.csv':
        for col, enum_map in enum_maps.items():
          if col in aggregate_columns:
            group_df[col] = group_df[col].map(enum_map)

        # Merge groupby df and aggregate
        sim_ct_base = len(base_df)
        sim_ct_feature = len(feature_df)
        if aggregate_columns:
          base_df = group_df.merge(base_df, 'outer', left_index=True, right_index=True).groupby(aggregate_columns)
          feature_df = group_df.merge(feature_df, 'outer', left_index=True, right_index=True).groupby(aggregate_columns)
          if aggregate_function == 'sum':
            base_df = base_df.sum().stack()
            feature_df = feature_df.sum().stack()
          elif aggregate_function == 'mean':
            base_df = base_df.mean().stack()
            feature_df = feature_df.mean().stack()
        else:
          if aggregate_function == 'sum':
            base_df = base_df.sum(numeric_only=True)
            feature_df = feature_df.sum(numeric_only=True)
          elif aggregate_function == 'mean':
            base_df = base_df.mean(numeric_only=True)
            feature_df = feature_df.mean(numeric_only=True)

    if not aggregate_columns: return

    # Write aggregate results df
    deltas = pd.DataFrame()
    deltas['base'] = base_df
    deltas['feature'] = feature_df
    deltas['diff'] = deltas['feature'] - deltas['base']
    deltas['% diff'] = 100*(deltas['diff']/deltas['base'])
    deltas = deltas.round(2)                          
    deltas.reset_index(level=aggregate_columns, inplace=True)
    deltas.index.name = 'enduse'
    sims_df = pd.DataFrame({'base': sim_ct_base,
                            'feature': sim_ct_feature,
                            'diff': 'n/a',
                            '% diff': 'n/a'},
                            index=['simulation_count'])
    sims_df[aggregate_columns] = 'n/a'
    deltas = pd.concat([sims_df, deltas])
    for group in aggregate_columns:
      first_col = deltas.pop(group)
      deltas.insert(0, group, first_col)

    basename, ext = os.path.splitext(file)
    if aggregate_columns:
        basename += '_{aggregate_column}'.format(aggregate_column=aggregate_columns[0])

    deltas.to_csv(os.path.join(self.export_folder, '{basename}_{aggregate_function}.csv'.format(basename=basename, aggregate_function=aggregate_function)))

  def visualize(self, display_column=None, aggregate_column=None, aggregate_function=None, excludes=[], enum_maps={}, column_maps={}):
    display_columns = []
    if display_column:
      display_columns.append(display_column)

    aggregate_columns = []
    if aggregate_column:
      aggregate_columns.append(aggregate_column)

    files = []
    for file in os.listdir(self.base_folder):
      if not file in excludes:
        files.append(file)

    if display_columns or aggregate_columns:
      base_characteristics_df = pd.read_csv(os.path.join(self.base_folder, 'results_characteristics.csv'), index_col=0)[display_columns + aggregate_columns]
      feature_characteristics_df = pd.read_csv(os.path.join(self.feature_folder, 'results_characteristics.csv'), index_col=0)[display_columns + aggregate_columns]

    def get_min_max(x_col, y_col, min_value, max_value):
        try:
          if 0.9 * np.min([x_col.min(), y_col.min()]) < min_value:
            min_value = 0.9 * np.min([x_col.min(), y_col.min()])
        except:
          pass
        try:
          if 1.1 * np.max([x_col.max(), y_col.max()]) > max_value:
            max_value = 1.1 * np.max([x_col.max(), y_col.max()])
        except:
          pass

        return(min_value, max_value)

    def add_error_lines(fig, showlegend, row, col, min_value, max_value):
        fig.add_trace(go.Scatter(x=[min_value, max_value], y=[min_value, max_value], line=dict(color='black', dash='dash', width=1), mode='lines', showlegend=showlegend, name='0% Error'), row=row, col=col)
        fig.add_trace(go.Scatter(x=[min_value, max_value], y=[0.9*min_value, 0.9*max_value], line=dict(color='black', dash='dashdot', width=1), mode='lines', showlegend=showlegend, name='+/- 10% Error'), row=row, col=col)
        fig.add_trace(go.Scatter(x=[min_value, max_value], y=[1.1*min_value, 1.1*max_value], line=dict(color='black', dash='dashdot', width=1), mode='lines', showlegend=False), row=row, col=col)

    def remove_columns(cols):
      for col in cols[:]:
        if all(v == 0 for v in base_df[col].values) and all(v == 0 for v in feature_df[col].values):
          cols.remove(col)
      for col in cols[:]:
        if '.include_' in col: cols.remove(col)
        if '.timeseries_' in col: cols.remove(col)
        if '.output_format' in col: cols.remove(col)
        if 'completed_status' in col: cols.remove(col)
        if '.applicable' in col: cols.remove(col)
        if 'upgrade_name' in col: cols.remove(col)
        if 'upgrade_cost_' in col: cols.remove(col)
      return cols

    for file in files:
      base_df = pd.read_csv(os.path.join(self.base_folder, file), index_col=0)
      feature_df = pd.read_csv(os.path.join(self.feature_folder, file), index_col=0)

      cols = sorted(list(set(base_df.columns) | set(feature_df.columns)))
      cols = remove_columns(cols)

      groups = [None]
      if display_columns:
        base_df = base_characteristics_df.join(base_df)
        feature_df = feature_characteristics_df.join(feature_df)

        for col, enum_map in enum_maps.items():
          if col in display_columns:
            for df in [base_df, feature_df]:
              df[col] = df[col].map(enum_map)

        groups = list(base_df[display_columns[0]].unique())        

      fig = make_subplots(rows=len(cols), cols=len(groups), subplot_titles=groups*len(cols), row_titles=[f'<b>{f}</b>' for f in cols], vertical_spacing=0.0015)

      nrow = 0
      for col in cols:
        nrow += 1
        for group in groups:
          ncol = groups.index(group) + 1
          showlegend = False
          if ncol == 1 and nrow == 1: showlegend = True

          x = base_df
          y = feature_df

          if group:
            x = x.loc[x[display_columns[0]] == group, :]
            y = y.loc[y[display_columns[0]] == group, :]

          if aggregate_function:
            if aggregate_function == 'sum':
              x = x.groupby(aggregate_columns).sum().reset_index()
              y = y.groupby(aggregate_columns).sum().reset_index()
            elif aggregate_function == 'mean':
              x = x.groupby(aggregate_columns).mean().reset_index()
              y = y.groupby(aggregate_columns).mean().reset_index()

            for agg_col in list(x[aggregate_columns[0]].unique()):
              fig.add_trace(go.Scatter(x=x[x[aggregate_columns[0]]==agg_col][col], y=y[y[aggregate_columns[0]]==agg_col][col], marker=dict(size=8), mode='markers', text=agg_col, name=agg_col, legendgroup=agg_col, showlegend=showlegend), row=nrow, col=ncol)
          else:
            fig.add_trace(go.Scatter(x=x[col], y=y[col], marker=dict(size=8), mode='markers', text=base_df.index, name='', legendgroup=col, showlegend=False), row=nrow, col=ncol)

          min_value, max_value = get_min_max(x[col], y[col], 0, 0)
          add_error_lines(fig, showlegend, nrow, ncol, min_value, max_value)
          fig.update_xaxes(title_text='base', row=nrow, col=ncol)
          fig.update_yaxes(title_text='feature', row=nrow, col=ncol)

      fig['layout'].update(title=file, template='plotly_white')
      fig.update_layout(width=800*len(groups), height=600*len(cols), autosize=False, font=dict(size=12))
      for i in fig['layout']['annotations']:
          i['font'] = dict(size=12) if i['text'] in cols else dict(size=12)

      basename, ext = os.path.splitext(file)
      if display_columns:
        basename += '_{display_column}'.format(display_column=display_columns[0])
      if aggregate_columns:
        basename += '_{aggregate_column}'.format(aggregate_column=aggregate_columns[0])
      if aggregate_function:
        basename += '_{aggregate_function}'.format(aggregate_function=aggregate_function)

      plotly.offline.plot(fig, filename=os.path.join(self.export_folder, '{basename}.html'.format(basename=basename)), auto_open=False)

if __name__ == '__main__':

  default_base_folder = 'workflow/tests/base_results'
  default_feature_folder = 'workflow/tests/results'
  default_export_folder = 'workflow/tests/comparisons'

  actions = [method for method in dir(BaseCompare) if method.startswith('__') is False]

  aggregate_columns = []
  aggregate_functions = ['sum', 'mean']

  parser = argparse.ArgumentParser()
  parser.add_argument('-b', '--base_folder', default=default_base_folder, help='The path of the base folder.')
  parser.add_argument('-f', '--feature_folder', default=default_feature_folder, help='The path of the feature folder.')
  parser.add_argument('-e', '--export_folder', default=default_export_folder, help='The path of the export folder.')
  parser.add_argument('-a', '--actions', action='append', choices=actions, help='The method to call.')
  parser.add_argument('-dc', '--display_column', help='How to organize the subplots columnwise.')
  parser.add_argument('-ac', '--aggregate_column', choices=aggregate_columns, help='On which column to aggregate data.')
  parser.add_argument('-af', '--aggregate_function', choices=aggregate_functions, help='Function to use for aggregating data.')
  args = parser.parse_args()

  if not os.path.exists(args.export_folder):
    os.makedirs(args.export_folder)

  compare = BaseCompare(args.base_folder, args.feature_folder, args.export_folder)

  if args.actions == None:
    args.actions = [] 

  for action in args.actions:
    if action == 'results':
      compare.results()
    elif action == 'visualize':
      compare.visualize()
